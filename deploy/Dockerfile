# syntax=docker/dockerfile:1.7

ARG RUBY_IMAGE=docker.io/library/ruby@sha256:654c8382a37d73dc8cb7dfe784d711ea82be6aafae2c8fee939149fd80a507c1
FROM ${RUBY_IMAGE}

ARG JEDNA_REF
ARG UNOBOT_REF
ARG PYTHON_VERSION=3.11.2-1+b1
ARG TINI_VERSION=0.19.0-1+b3

LABEL org.opencontainers.image.title="unobot neural IRC player" \
      org.opencontainers.image.description="Ruby IRC client with local Jedna MaskablePPO inference" \
      org.opencontainers.image.source="https://github.com/kaiks/unobot" \
      org.opencontainers.image.revision="${UNOBOT_REF}" \
      org.opencontainers.image.jedna.revision="${JEDNA_REF}"

ENV APP_HOME=/unobot \
    BUNDLE_PATH=/opt/bundle \
    BUNDLE_WITHOUT=development \
    PYTHONUNBUFFERED=1 \
    PYTHONDONTWRITEBYTECODE=1 \
    MPLCONFIGDIR=/tmp/matplotlib \
    XDG_CACHE_HOME=/tmp/cache \
    OMP_NUM_THREADS=1 \
    MKL_NUM_THREADS=1 \
    OPENBLAS_NUM_THREADS=1

RUN apt-get update -q && \
    apt-get install -y --no-install-recommends \
      ca-certificates=20230311+deb12u1 \
      git=1:2.39.5-0+deb12u3 \
      python3=${PYTHON_VERSION} \
      python3-venv=${PYTHON_VERSION} \
      tini=${TINI_VERSION} && \
    rm -rf /var/lib/apt/lists/*

WORKDIR ${APP_HOME}

COPY Gemfile Gemfile.lock ./
RUN gem install bundler -v 4.0.16 --no-document && \
    bundle config set frozen true && \
    bundle install && \
    apt-get purge -y git && \
    apt-get autoremove -y && \
    rm -rf /var/lib/apt/lists/*

COPY deploy/requirements-neural.lock /tmp/requirements-neural.lock
RUN python3 -m venv /opt/venv && \
    /opt/venv/bin/pip install --no-cache-dir \
      --require-hashes \
      --extra-index-url https://download.pytorch.org/whl/cpu \
      -r /tmp/requirements-neural.lock && \
    /opt/venv/bin/pip check && \
    /opt/venv/bin/python -c "import gymnasium, numpy, sb3_contrib, stable_baselines3, torch; assert torch.__version__ == '2.8.0+cpu'; assert stable_baselines3.__version__ == sb3_contrib.__version__ == '2.7.0'; assert gymnasium.__version__ == '1.2.0'; assert numpy.__version__ == '2.3.5'" && \
    /opt/venv/bin/python -c "from importlib.metadata import version; expected = {'filelock': '3.31.1', 'fonttools': '4.63.0', 'Jinja2': '3.1.6', 'Pillow': '12.3.0', 'pip': '26.1.2', 'setuptools': '83.0.0'}; assert {name: version(name) for name in expected} == expected" && \
    rm /tmp/requirements-neural.lock

# The named context contains exactly these six files plus LICENSE, archived
# from JEDNA_REF. Training code and checkpoints never enter BuildKit.
COPY --from=jedna_runtime extension-gems/jedna-tournaments/examples/simple_agent.rb /opt/jedna-tournaments/examples/simple_agent.rb
COPY --from=jedna_runtime extension-gems/jedna-tournaments/examples/crushing_agent.rb /opt/jedna-tournaments/examples/crushing_agent.rb
COPY --from=jedna_runtime extension-gems/jedna-tournaments/examples/crushing_agent/baseline_strategy.rb /opt/jedna-tournaments/examples/crushing_agent/baseline_strategy.rb
COPY --from=jedna_runtime extension-gems/jedna-tournaments/examples/rl_agent/__init__.py /opt/jedna-tournaments/examples/rl_agent/__init__.py
COPY --from=jedna_runtime extension-gems/jedna-tournaments/examples/rl_agent/encoding.py /opt/jedna-tournaments/examples/rl_agent/encoding.py
COPY --from=jedna_runtime extension-gems/jedna-tournaments/examples/rl_agent/sb3_opponent.py /opt/jedna-tournaments/examples/rl_agent/sb3_opponent.py
COPY --from=jedna_runtime LICENSE /opt/jedna-tournaments/JEDNA-LICENSE

COPY bot_config.rb uno_bot_starter.rb ./
COPY lib/ ./lib/
COPY bin/ ./bin/
COPY deploy/entrypoint ./deploy/entrypoint

RUN groupadd --gid 10001 unobot && \
    useradd --uid 10001 --gid 10001 --home-dir ${APP_HOME} --no-create-home --shell /usr/sbin/nologin unobot && \
    mkdir -p logs /run/unobot && \
    chown -R unobot:unobot logs /run/unobot && \
    chmod 0700 /run/unobot && \
    chmod 0755 deploy/entrypoint bin/unobotctl && \
    find /opt/jedna-tournaments -type d -exec chmod 0555 {} + && \
    find /opt/jedna-tournaments -type f -exec chmod 0444 {} + && \
    test ! -e /models/jedna_multiplayer_v3.zip && \
    ruby --version | grep -F 'ruby 4.0.6' && \
    python3 --version | grep -F 'Python 3.11.2'

USER 10001:10001

ENV UNO_TOURNAMENT_EXAMPLES=/opt/jedna-tournaments/examples \
    UNO_NEURAL_PYTHON=/opt/venv/bin/python \
    UNO_NEURAL_CHECKPOINT=/models/jedna_multiplayer_v3.zip \
    UNO_OPERATIONS_SOCKET=/run/unobot/control.sock

ENTRYPOINT ["/usr/bin/tini", "--", "/unobot/deploy/entrypoint"]
CMD ["bundle", "exec", "ruby", "uno_bot_starter.rb"]
