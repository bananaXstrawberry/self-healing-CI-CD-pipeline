FROM python:3.12-slim

# Run as non-root inside the sandbox so a misbehaving fixer agent cannot
# touch the host's filesystem. The "agent" user has no sudo capability and
# only owns /workspace.
RUN useradd --create-home --shell /bin/bash agent
WORKDIR /workspace
COPY requirements.txt /workspace/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY src /workspace/src
RUN chown -R agent:agent /workspace
USER agent

ENV PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    PIPELINE_LOG_PATH=/workspace/pipeline.log

ENTRYPOINT ["python", "-m", "src.main"]
