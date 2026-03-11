FROM docker.litellm.ai/berriai/litellm:main-stable

COPY config.yaml /app/config.yaml

CMD ["--config", "/app/config.yaml", "--port", "4000", "--num_workers", "4"]
