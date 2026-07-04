FROM python:3.11-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application files
COPY server.py .
COPY config.json .

# Expose API port
EXPOSE 8080

# Inside a container we must bind all interfaces. Set API_KEY (e.g. via
# docker-compose environment or --env) to require auth on the trading endpoints.
ENV HOST=0.0.0.0
ENV PORT=8080

# Run the server (no --reload in production)
CMD ["python", "server.py"]
