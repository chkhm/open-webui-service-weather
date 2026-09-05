# SPDX-License-Identifier: MIT
# Copyright (c) 2026 Christoph Kuhmuench
FROM python:3.11-slim

WORKDIR /app
COPY currency_service.py /app/
RUN pip install --no-cache-dir flask requests

EXPOSE 5006

CMD ["python", "currency_service.py"]
