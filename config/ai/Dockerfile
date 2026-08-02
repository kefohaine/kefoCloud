FROM python:3.12-slim

WORKDIR /app

COPY requirements.txt .

RUN pip install --no-cache-dir -r requirements.txt \
    && pip install --no-cache-dir \
    --extra-index-url https://abetlen.github.io/llama-cpp-python/whl/cpu \
    llama-cpp-python

COPY ../../content/ai/app.py .

EXPOSE 8000

CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000"]
