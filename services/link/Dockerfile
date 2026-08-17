FROM python:3.12-slim
WORKDIR /app
RUN pip install --no-cache-dir flask==3.0.3
COPY app.py /app/
COPY templates /app/templates
EXPOSE 5000
CMD ["python", "app.py"]