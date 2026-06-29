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

API_TOKEN_FILE = "/opt/wireguard-api/.api_token"
with open(API_TOKEN_FILE, "r") as f:
    API_TOKEN = f.read().strip()

WG_MANAGER = "/etc/wireguard/scripts/wg-manager.sh"
WG_CONFIG = "/etc/wireguard/wg0.conf"
META_FILE = "/etc/wireguard/clients_meta.json"

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

app = FastAPI(title="WireGuard Bot API")

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
    """Парсит wg0.conf и возвращает словарь {публичный_ключ: имя_клиента}"""
    peer_names = {}
    try:
        with open(WG_CONFIG, "r", encoding='utf-8', errors='ignore') as f:
            lines = f.readlines()
        current_name = None
        current_pubkey = None
        for line in lines:
            # Удаляем лишние пробелы и символы перевода строки
            line = line.strip()
            if not line:
                continue
            # Ищем начало секции клиента
            if line.startswith("# BEGIN_PEER "):
                # Извлекаем имя после "# BEGIN_PEER "
                current_name = line[len("# BEGIN_PEER "):].strip()
                logger.debug(f"Found BEGIN_PEER: {current_name}")
            # Ищем публичный ключ внутри секции
            if line.startswith("PublicKey = "):
                current_pubkey = line[len("PublicKey = "):].strip()
                logger.debug(f"Found PublicKey: {current_pubkey[:20]}...")
            # Если нашли конец секции и у нас есть имя и ключ – сохраняем
            if line.startswith("# END_PEER ") and current_name and current_pubkey:
                peer_names[current_pubkey] = current_name
                logger.info(f"Mapped {current_name} -> {current_pubkey[:20]}...")
                current_name = None
                current_pubkey = None
        logger.info(f"Total peer name mappings found: {len(peer_names)}")
    except Exception as e:
        logger.error(f"Failed to parse peer names: {e}")
    return peer_names

@app.post("/add_client")
async def add_client(request: AddClientRequest, auth: bool = Depends(verify_token)):
    name = request.name
    dur = request.duration_seconds
    logger.info(f"Add client {name}, duration {dur}")
    try:
        if dur > 0:
            cmd = ["/usr/bin/sudo", WG_MANAGER, "add-temp", name, str(dur)]
        else:
            cmd = ["/usr/bin/sudo", WG_MANAGER, "add", name]
        env = os.environ.copy()
        env['PATH'] = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=30, env=env)
        
        logger.info(f"STDOUT: {result.stdout}")
        if result.stderr:
            logger.warning(f"STDERR: {result.stderr}")
        
        if result.returncode != 0:
            raise HTTPException(status_code=500, detail=result.stderr)
        
        time.sleep(0.5)
        
        conf_path = None
        png_path = None
        for line in result.stdout.splitlines():
            if "Конфиг сохранён:" in line:
                conf_path = line.split("Конфиг сохранён:")[-1].strip()
            if "QR-код сохранён:" in line:
                png_path = line.split("QR-код сохранён:")[-1].strip()
        
        if not conf_path:
            conf_path = f"/root/{name}.conf"
            png_path = f"/root/{name}.png"
        
        if not os.path.exists(conf_path):
            time.sleep(1)
            if not os.path.exists(conf_path):
                try:
                    ls_result = subprocess.run(["ls", "-la", "/root"], capture_output=True, text=True)
                    logger.error(f"ls /root: {ls_result.stdout}")
                except:
                    pass
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
        logger.info(f"Reading meta file from {META_FILE}")
        with open(META_FILE, "r") as f:
            data = json.load(f)
        logger.info(f"Loaded {len(data)} clients")
        return {"clients": data}
    except FileNotFoundError:
        logger.warning(f"Meta file {META_FILE} not found")
        return {"clients": {}}
    except PermissionError as e:
        logger.error(f"Permission denied reading {META_FILE}: {e}")
        raise HTTPException(status_code=500, detail=f"Permission denied: {e}")
    except json.JSONDecodeError as e:
        logger.error(f"JSON decode error in {META_FILE}: {e}")
        raise HTTPException(status_code=500, detail=f"Invalid JSON: {e}")
    except Exception as e:
        logger.exception(f"Unexpected error reading {META_FILE}: {e}")
        raise HTTPException(status_code=500, detail=str(e))

@app.get("/stats")
async def stats(auth: bool = Depends(verify_token)):
    try:
        # Получаем соответствие ключей и имён
        peer_names = get_peer_names()
        
        # Выполняем wg show
        cmd = ["/usr/bin/sudo", "/usr/bin/wg", "show"]
        env = os.environ.copy()
        env['PATH'] = '/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin'
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=5, env=env)
        if result.returncode != 0:
            logger.error(f"wg show failed: {result.stderr}")
            raise HTTPException(status_code=500, detail=result.stderr)
        
        output = result.stdout
        # Заменяем ключи на имена в выводе
        lines = output.splitlines()
        new_lines = []
        for line in lines:
            if line.startswith("peer: "):
                # Извлекаем ключ
                parts = line.split()
                if len(parts) >= 2:
                    pubkey = parts[1]
                    if pubkey in peer_names:
                        # Заменяем ключ на "имя (ключ)"
                        new_line = f"peer: {peer_names[pubkey]} ({pubkey})"
                        # Добавляем остальную часть строки (если есть)
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
