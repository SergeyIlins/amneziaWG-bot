#!/usr/bin/env python3
import subprocess
import os
import json
import logging
import time
import re
from fastapi import FastAPI, HTTPException, Depends, Header
from pydantic import BaseModel
from typing import Optional
import secrets

API_TOKEN_FILE = "/opt/amneziawg-api/.api_token"
if not os.path.exists(API_TOKEN_FILE):
    os.makedirs(os.path.dirname(API_TOKEN_FILE), exist_ok=True)
    with open(API_TOKEN_FILE, "w") as f:
        f.write(secrets.token_hex(32))
with open(API_TOKEN_FILE, "r") as f:
    API_TOKEN = f.read().strip()

WG_MANAGER = "/usr/local/bin/awg-manager"
WG_CONFIG = "/etc/amneziawg/awg0.conf"
META_FILE = "/etc/amneziawg/clients_meta.json"

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="AmneziaWG Bot API")

def verify_token(authorization: Optional[str] = Header(None)):
    if not authorization:
        raise HTTPException(status_code=403, detail="Missing token")
    scheme, _, token = authorization.partition(' ')
    if scheme.lower() != 'bearer' or not secrets.compare_digest(token, API_TOKEN):
        raise HTTPException(status_code=403, detail="Invalid token")
    return True

class AddClientRequest(BaseModel):
    name: str
    duration_seconds: int = 0

class DeleteClientRequest(BaseModel):
    name: str

def get_peer_names():
    peer_names = {}
    try:
        with open(WG_CONFIG, "r", encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
        current_name = None
        current_pubkey = None
        for line in lines:
            line = line.strip()
            if not line:
                continue
            if line.startswith("# BEGIN_PEER "):
                current_name = line[len("# BEGIN_PEER "):].strip()
            if line.startswith("PublicKey = "):
                current_pubkey = line[len("PublicKey = "):].strip()
            if line.startswith("# END_PEER ") and current_name and current_pubkey:
                peer_names[current_pubkey] = current_name
                current_name = None
                current_pubkey = None
    except Exception as e:
        logger.error(f"Failed to parse peer names: {e}")
    return peer_names

@app.post("/add_client")
async def add_client(request: AddClientRequest, auth: bool = Depends(verify_token)):
    name = request.name
    dur = request.duration_seconds
    logger.info(f"Add client {name}, duration {dur}")
    try:
        cmd = ["/usr/bin/sudo", WG_MANAGER, "add-temp" if dur > 0 else "add", name, str(dur) if dur > 0 else ""]
        env = os.environ.copy()
        env['PATH'] = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=env)
        logger.info(f"STDOUT: {result.stdout}")
        if result.stderr:
            logger.warning(f"STDERR: {result.stderr}")
        if result.returncode != 0:
            raise HTTPException(status_code=500, detail=result.stderr)
        time.sleep(0.5)
        # Проверяем оба возможных пути
        conf_path = f"/root/amneziawg-clients/{name}.conf"
        png_path = f"/root/amneziawg-clients/{name}.png"
        if not os.path.exists(conf_path):
            # Возможно, создался в /root/
            alt_conf = f"/root/{name}.conf"
            if os.path.exists(alt_conf):
                conf_path = alt_conf
                png_path = f"/root/{name}.png"
            else:
                raise HTTPException(status_code=500, detail=f"Config file not found at {conf_path}")
        return {"status": "success", "conf_path": conf_path, "png_path": png_path}
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Timeout")
    except Exception as e:
        logger.exception(e)
        raise HTTPException(status_code=500, detail=str(e))

@app.post("/delete_client")
async def delete_client(request: DeleteClientRequest, auth: bool = Depends(verify_token)):
    name = request.name
    logger.info(f"Delete client {name}")
    try:
        cmd = ["/usr/bin/sudo", WG_MANAGER, "del", name]
        env = os.environ.copy()
        env['PATH'] = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=15, env=env)
        if result.returncode != 0:
            raise HTTPException(status_code=500, detail=result.stderr)
        return {"status": "success"}
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Timeout")
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/list_clients")
async def list_clients(auth: bool = Depends(verify_token)):
    try:
        with open(META_FILE, "r") as f:
            data = json.load(f)
        return {"clients": data}
    except FileNotFoundError:
        return {"clients": {}}
    except Exception as e:
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/stats")
async def stats(auth: bool = Depends(verify_token)):
    try:
        peer_names = get_peer_names()
        cmd = ["/usr/bin/sudo", "/usr/bin/awg", "show"]
        env = os.environ.copy()
        env['PATH'] = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5, env=env)
        if result.returncode != 0:
            raise HTTPException(status_code=500, detail=result.stderr)
        output = result.stdout
        lines = output.splitlines()
        new_lines = []
        for line in lines:
            if line.startswith("peer: "):
                parts = line.split()
                if len(parts) >= 2:
                    pubkey = parts[1]
                    if pubkey in peer_names:
                        new_line = f"peer: {peer_names[pubkey]} ({pubkey})"
                        if len(parts) > 2:
                            new_line += " " + " ".join(parts[2:])
                        new_lines.append(new_line)
                    else:
                        new_lines.append(line)
                else:
                    new_lines.append(line)
            else:
                new_lines.append(line)
        output_with_names = "\n".join(new_lines)
        return {"status": "success", "output": output_with_names}
    except subprocess.TimeoutExpired:
        raise HTTPException(status_code=504, detail="Timeout")
    except Exception as e:
        logger.exception(e)
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/health")
async def health():
    return {"status": "ok"}
