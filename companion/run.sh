#!/bin/bash
# Starts the PugLogs companion. The first run sets up its Python environment.
set -e
cd "$(dirname "$0")"
if [ ! -x .venv/bin/python ]; then
	echo "First run: installing dependencies..."
	python3 -m venv .venv
	.venv/bin/pip install --quiet -r requirements.txt
fi
exec .venv/bin/python app.py "$@"
