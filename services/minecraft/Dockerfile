FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir flask==3.0.3 mcrcon==0.7.0
EXPOSE 5000
CMD ["python", "/app/src/app.py"]
