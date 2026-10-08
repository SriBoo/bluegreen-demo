#!/bin/sh
# Pre-deploy gate for the Catalyst pipeline.
#
# Runs BEFORE `catalyst deploy`. If app.py doesn't compile, doesn't start, or
# doesn't answer / and /health, this exits non-zero: the pipeline fails, the
# deploy step never runs, and test-app keeps serving the current version.
set -eu

PORT=9555

PY=$(command -v python3 || command -v python || true)
if [ -z "$PY" ]; then
    echo "python3 not found in pipeline image - installing it"
    SUDO=""
    if [ "$(id -u)" != "0" ] && command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi
    if command -v apt-get >/dev/null 2>&1; then
        $SUDO apt-get update -qq && $SUDO apt-get install -y -qq python3 >/dev/null
    elif command -v apk >/dev/null 2>&1; then
        $SUDO apk add --no-cache python3 >/dev/null
    elif command -v yum >/dev/null 2>&1; then
        $SUDO yum install -y -q python3
    fi
    PY=$(command -v python3 || true)
    if [ -z "$PY" ]; then
        echo "GATE FAILED: python3 is not available in the pipeline image"
        exit 1
    fi
fi
echo "Using $($PY --version 2>&1)"

echo "1/3 Compiling app.py"
if ! $PY -c "import sys; compile(open('app.py').read(), 'app.py', 'exec')"; then
    echo "GATE FAILED: app.py does not compile - deploy skipped, test-app unchanged"
    exit 1
fi

echo "2/3 Starting app.py on port $PORT"
X_ZOHO_CATALYST_LISTEN_PORT=$PORT $PY app.py > /tmp/predeploy-app.log 2>&1 &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

check() {
    $PY -c "import urllib.request,sys; r=urllib.request.urlopen('http://127.0.0.1:$PORT$1', timeout=2); sys.exit(0 if r.status == 200 else 1)" 2>/dev/null
}

echo "3/3 Checking /health and /"
i=0
while [ $i -lt 15 ]; do
    if check /health && check /; then
        echo "GATE PASSED: app is healthy - continuing to deploy"
        exit 0
    fi
    if ! kill -0 $PID 2>/dev/null; then
        break
    fi
    i=$((i + 1))
    sleep 1
done

echo "--- app output ---"
cat /tmp/predeploy-app.log || true
echo "GATE FAILED: app is not healthy - deploy skipped, test-app unchanged"
exit 1
