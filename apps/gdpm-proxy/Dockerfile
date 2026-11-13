FROM python:3.12-slim
# 只用标准库：不在构建期装任何包，避免镜像站不可用拖垮部署。
COPY proxy.py /proxy.py
ENV PYTHONUNBUFFERED=1
EXPOSE 3128
ENTRYPOINT ["python3", "/proxy.py"]
