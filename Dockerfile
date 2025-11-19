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

# Run the server
CMD ["uvicorn", "server:app", "--host", "0.0.0.0", "--port", "8080", "--reload"]
