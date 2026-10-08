FROM python:3.12-slim
WORKDIR /app
COPY requirements.txt .
RUN pip install --trusted-host pypi.org --trusted-host pypi.python.org --trusted-host files.pythonhosted.org -r requirements.txt
COPY app.py .
CMD ["gunicorn", "-b", "0.0.0.0:5000", "app:app"]
