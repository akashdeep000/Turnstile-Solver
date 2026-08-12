FROM python:3.12-slim

ENV PIP_NO_CACHE_DIR=1
ENV PYTHONUNBUFFERED=1

RUN apt-get update && \
    apt-get install -y --no-install-recommends curl ca-certificates && \
    rm -rf /var/lib/apt/lists/*

WORKDIR /app

COPY requirements.txt /app/requirements.txt
RUN pip install -r requirements.txt
RUN patchright install chromium && patchright install-deps chromium || true

COPY api_solver.py /app/api_solver.py

EXPOSE 5000

CMD ["python", "api_solver.py", "--headless", "True", \
     "--useragent", "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/149.0.0.0 Safari/537.36", \
     "--browser_type", "chromium", "--thread", "4", "--host", "0.0.0.0", "--port", "5000"]