FROM python:3.12-slim

# OpenCV (lo usa ultralytics) necesita estas librerías del sistema; tzdata,
# para que fechas y carpetas de fotos usen la hora de Ecuador.
RUN apt-get update && apt-get install -y --no-install-recommends libgl1 libglib2.0-0 tzdata \
    && rm -rf /var/lib/apt/lists/*
ENV TZ=America/Guayaquil

WORKDIR /app
RUN pip install --no-cache-dir torch==2.14.1 torchvision==0.29.1 --index-url https://download.pytorch.org/whl/cpu
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .
COPY web ./web
COPY modelos/best.pt /modelos/best.pt

ENV TAXIFF_DATOS=/datos TAXIFF_MODELO=/modelos/best.pt
VOLUME /datos
EXPOSE 8000
CMD ["uvicorn", "app:app", "--host", "0.0.0.0", "--port", "8000", "--proxy-headers"]
