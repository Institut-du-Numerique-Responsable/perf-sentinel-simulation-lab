# tracegen: parameterized OTLP load generator with I/O semantics.
# Built and imported into k3d by scripts/seed-tracegen.sh, never pulled.
FROM python:3.15-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY tracegen.py templates.py ./

USER 65534
ENTRYPOINT ["python3", "/app/tracegen.py"]
