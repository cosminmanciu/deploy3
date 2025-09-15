#!/bin/bash

# WHMCS Docker Rebuild Script
# This script helps fix macOS Docker issues by clearing cache and rebuilding

echo "🧹 Cleaning up Docker containers and volumes..."
docker-compose down -v --remove-orphans

echo "🗑️  Removing unused Docker resources..."
docker system prune -f

echo "🏗️  Building container from scratch..."
docker-compose build --no-cache

echo "🚀 Starting services..."
docker-compose up -d

echo "📋 Showing container status..."
docker-compose ps

echo "📜 Showing recent logs..."
docker-compose logs --tail=50 -f