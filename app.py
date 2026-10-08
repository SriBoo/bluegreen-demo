import os
from flask import Flask
app = Flask(__name__)
VERSION = os.getenv("APP_VERSION", "v1")

@app.route("/")
def home():
    return f"Hello! Updated release, version {VERSION}\n"

@app.route("/health")
def health():
    return "ok", 200
