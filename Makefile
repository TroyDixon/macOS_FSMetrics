.PHONY: venv install test run-collector run-collector-once run-dashboard demo clean

PYTHON ?= python3
VENV := .venv
BIN := $(VENV)/bin

venv:
	$(PYTHON) -m venv $(VENV)

install: venv
	$(BIN)/pip install --upgrade pip
	$(BIN)/pip install -r requirements.txt

test: install
	$(BIN)/python -m unittest discover -s tests -v

# Runs the collector daemon continuously using config.yaml.
# On macOS with simulate:false, this shells out to diskutil/iostat/nfsstat
# and requires the volumes listed in config.yaml to actually exist.
run-collector: install
	$(BIN)/python -m collector.daemon --config config.yaml

# Single poll cycle, useful for quick sanity checks / CI.
run-collector-once: install
	$(BIN)/python -m collector.daemon --config config.yaml --once

run-dashboard: install
	$(BIN)/python dashboard/app.py --db metrics.db --port 5050

# One-command demo: seeds a few collection cycles in simulate mode (works on
# any OS, no macOS or real disks required) then launches the dashboard.
demo: install
	rm -f metrics.db
	for i in 1 2 3 4 5 6; do $(BIN)/python -m collector.daemon --config config.yaml --once; sleep 1; done
	@echo ""
	@echo "Demo data seeded. Starting dashboard at http://127.0.0.1:5050 ..."
	$(BIN)/python dashboard/app.py --db metrics.db --port 5050

clean:
	rm -rf $(VENV) metrics.db __pycache__ collector/__pycache__ dashboard/__pycache__ tests/__pycache__
