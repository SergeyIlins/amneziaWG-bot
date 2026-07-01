#!/usr/bin/env python3
import logging
import httpx
import json
import os
import re
from datetime import datetime
from telegram import Update, InlineKeyboardButton, InlineKeyboardMarkup, BotCommand
from telegram.ext import Application, CommandHandler, CallbackQueryHandler, MessageHandler, filters, ContextTypes

TELEGRAM_BOT_TOKEN = os.getenv("TELEGRAM_BOT_TOKEN")
if not TELEGRAM_BOT_TOKEN:
    raise ValueError("TELEGRAM_BOT_TOKEN не задан")

API_URL = os.getenv("API_URL", "http://127.0.0.1:8000")
ALLOWED_USERS_STR = os.getenv("ADMIN_IDS", "")
ALLOWED_USERS = set()
if ALLOWED_USERS_STR:
    try:
        ALLOWED_USERS = {int(uid.strip()) for uid in ALLOWED_USERS_STR.split(",") if uid.strip()}
    except ValueError:
        raise ValueError("ADMIN_IDS должен содержать числа через запятую")

API_TOKEN_FILE = "/opt/amneziawg-api/.api_token"
if os.path.exists(API_TOKEN_FILE):
    with open(API_TOKEN_FILE, "r") as f:
        API_TOKEN = f.read().strip()
else:
    # Создаём токен, если отсутствует
    os.makedirs(os.path.dirname(API_TOKEN_FILE), exist_ok=True)
    import secrets
    API_TOKEN = secrets.token_hex(32)
    with open(API_TOKEN_FILE, "w") as f:
        f.write(API_TOKEN)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

DURATION_MAP = {
    "24 часа": 86400,
    "1 месяц": 2592000,
    "3 месяца": 7776000,
    "6 месяцев": 15552000,
    "12 месяцев": 31104000,
    "Постоянный": 0
}

def get_main_menu_keyboard():
    return InlineKeyboardMarkup([
        [InlineKeyboardButton("➕ Добавить клиента", callback_data="add_client")],
        [InlineKeyboardButton("❌ Удалить клиента", callback_data="del_client")],
        [InlineKeyboardButton("📋 Список клиентов", callback_data="list_clients")],
        [InlineKeyboardButton("📊 Статистика", callback_data="stats")]
    ])

async def send_main_menu(chat_id, context, text="Главное меню:"):
    await context.bot.send_message(chat_id=chat_id, text=text, reply_markup=get_main_menu_keyboard())

def is_allowed(update: Update) -> bool:
    user_id = update.effective_user.id
    if user_id not in ALLOWED_USERS:
        logger.warning(f"Доступ запрещён для пользователя {user_id}")
        return False
    return True

async def call_api(endpoint: str, data: dict = None):
    async with httpx.AsyncClient(timeout=30.0) as client:
        headers = {"Authorization": f"Bearer {API_TOKEN}"}
        if data:
            response = await client.post(f"{API_URL}/{endpoint}", json=data, headers=headers)
        else:
            response = await client.get(f"{API_URL}/{endpoint}", headers=headers)
        response.raise_for_status()
        return response.json()

async def set_commands(app):
    await app.bot.set_my_commands([BotCommand("menu", "Главное меню"), BotCommand("id", "Мой ID")])

async def start(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.message.reply_text("⛔ Доступ запрещён.")
        return
    await update.message.reply_text("Добро пожаловать! Используйте /menu.")

async def show_id(update: Update, context: ContextTypes.DEFAULT_TYPE):
    await update.message.reply_text(f"Ваш ID: `{update.effective_user.id}`", parse_mode="Markdown")

async def menu(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.message.reply_text("⛔ Нет доступа.")
        return
    await update.message.reply_text("Главное меню:", reply_markup=get_main_menu_keyboard())

async def button_handler(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.callback_query.answer("⛔ Нет доступа", show_alert=True)
        return
    query = update.callback_query
    await query.answer()
    data = query.data

    if data == "add_client":
        keyboard = [
            [InlineKeyboardButton("24 часа", callback_data="dur_86400")],
            [InlineKeyboardButton("1 месяц", callback_data="dur_2592000")],
            [InlineKeyboardButton("3 месяца", callback_data="dur_7776000")],
            [InlineKeyboardButton("6 месяцев", callback_data="dur_15552000")],
            [InlineKeyboardButton("12 месяцев", callback_data="dur_31104000")],
            [InlineKeyboardButton("Постоянный", callback_data="dur_0")],
            [InlineKeyboardButton("◀️ Назад", callback_data="back")]
        ]
        await query.edit_message_text("Выберите срок:", reply_markup=InlineKeyboardMarkup(keyboard))
    elif data.startswith("dur_"):
        seconds = int(data.split("_")[1])
        context.user_data['duration'] = seconds
        keyboard = [[InlineKeyboardButton("◀️ Назад", callback_data="back")]]
        await query.edit_message_text("Введите имя клиента (латиница, 3-20 символов, - и _):", reply_markup=InlineKeyboardMarkup(keyboard))
        context.user_data['awaiting_name'] = True
    elif data == "del_client":
        context.user_data['awaiting_delete'] = True
        keyboard = [[InlineKeyboardButton("◀️ Назад", callback_data="back")]]
        await query.edit_message_text("Введите имя клиента для удаления:", reply_markup=InlineKeyboardMarkup(keyboard))
    elif data == "list_clients":
        try:
            res = await call_api("list_clients")
            clients = res.get("clients", {})
            if not clients:
                text = "Нет клиентов."
            else:
                msg = "📋 *Список клиентов:*\n"
                for name, info in clients.items():
                    expires = info.get("expires", 0)
                    ip = info.get("ip", "?")
                    if expires == 0:
                        expire_str = "♾️ постоянный"
                    else:
                        expire_str = f"до {datetime.fromtimestamp(expires).strftime('%Y-%m-%d %H:%M')}"
                    msg += f"• *{name}* — {expire_str} (IP: {ip})\n"
                text = msg
            keyboard = [[InlineKeyboardButton("◀️ Назад", callback_data="back")]]
            await query.edit_message_text(text, parse_mode="Markdown", reply_markup=InlineKeyboardMarkup(keyboard))
        except Exception as e:
            await query.edit_message_text(f"Ошибка: {e}")
    elif data == "stats":
        try:
            res = await call_api("stats")
            output = res.get("output", "")
            if len(output) > 4000:
                output = output[:3500] + "\n... (обрезано)"
            text = f"📊 *Статистика:*\n```\n{output}\n```"
            keyboard = [[InlineKeyboardButton("◀️ Назад", callback_data="back")]]
            await query.edit_message_text(text, parse_mode="Markdown", reply_markup=InlineKeyboardMarkup(keyboard))
        except Exception as e:
            await query.edit_message_text(f"Ошибка: {e}")
    elif data == "back":
        await query.edit_message_text("Главное меню:", reply_markup=get_main_menu_keyboard())

async def handle_message(update: Update, context: ContextTypes.DEFAULT_TYPE):
    if not is_allowed(update):
        await update.message.reply_text("⛔ Нет доступа.")
        return
    text = update.message.text.strip()
    chat_id = update.effective_chat.id

    if context.user_data.get('awaiting_name'):
        name = text
        if not re.match(r'^[a-zA-Z0-9_-]{3,20}$', name):
            await update.message.reply_text("Некорректное имя. Попробуйте снова или нажмите Отмена.")
            return
        duration = context.user_data.get('duration', 0)
        try:
            res = await call_api("add_client", {"name": name, "duration_seconds": duration})
            conf_path = res.get("conf_path")
            png_path = res.get("png_path")
            if conf_path:
                with open(conf_path, 'rb') as f:
                    await update.message.reply_document(document=f, filename=f"{name}.conf")
            if png_path:
                with open(png_path, 'rb') as f:
                    await update.message.reply_photo(photo=f, caption=f"QR-код для {name}")
            await update.message.reply_text(f"✅ Клиент {name} добавлен.")
            await send_main_menu(chat_id, context, "Что делаем дальше?")
        except Exception as e:
            await update.message.reply_text(f"❌ Ошибка: {e}")
            await send_main_menu(chat_id, context, "Произошла ошибка.")
        context.user_data.pop('awaiting_name', None)
        context.user_data.pop('duration', None)
    elif context.user_data.get('awaiting_delete'):
        name = text
        try:
            await call_api("delete_client", {"name": name})
            await update.message.reply_text(f"🗑️ Клиент {name} удалён.")
            await send_main_menu(chat_id, context, "Что делаем дальше?")
        except Exception as e:
            await update.message.reply_text(f"❌ Ошибка: {e}")
            await send_main_menu(chat_id, context, "Произошла ошибка.")
        context.user_data['awaiting_delete'] = False
    else:
        await update.message.reply_text("Используйте /menu для управления.")

def main():
    app = Application.builder().token(TELEGRAM_BOT_TOKEN).build()
    app.add_handler(CommandHandler("start", start))
    app.add_handler(CommandHandler("menu", menu))
    app.add_handler(CommandHandler("id", show_id))
    app.add_handler(CallbackQueryHandler(button_handler))
    app.add_handler(MessageHandler(filters.TEXT & ~filters.COMMAND, handle_message))
    app.post_init = set_commands
    app.run_polling()

if __name__ == "__main__":
    main()
