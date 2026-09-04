# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Christoph Kuhmuench
FROM python:3.11-slim

WORKDIR /app
COPY weather_service.py /app/
RUN pip install --no-cache-dir flask requests

ENV OWM_API_KEY=${OWM_API_KEY}
EXPOSE 5005

CMD ["python", "weather_service.py"]
