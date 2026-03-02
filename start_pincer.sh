#!/bin/bash
PROJECT_DIR="/home/micelio/Pincer/pincer"
cd $PROJECT_DIR

# 1. Kill everything
pkill -9 -u micelio beam.smp
pkill -9 -u micelio mix

# 2. Get Token
TOKEN=$(grep TELEGRAM_BOT_TOKEN .env | cut -d= -f2)

# 3. Clean Webhook (CURL)
echo "Limpando Webhook..."
curl -s "https://api.telegram.org/bot$TOKEN/deleteWebhook?drop_pending_updates=true"

# 4. Start Bot
echo "Iniciando Pincer..."
mix run --no-halt
