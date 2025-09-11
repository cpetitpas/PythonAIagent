import os
import fitz
from fastapi import FastAPI, UploadFile, File, Form, BackgroundTasks, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse, PlainTextResponse
from fastapi.staticfiles import StaticFiles
from openai import OpenAI
import qdrant_client
from qdrant_client.http import models
import uuid
import logging
from logging.handlers import RotatingFileHandler
import sys
from pathlib import Path
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.responses import Response

# =========================
# Path Helper
# =========================
def resource_path(relative_path: str) -> Path:
    """
    Get absolute path to resource, works for dev, PyInstaller onefile, and onedir.
    """
if getattr(sys, 'frozen', False):
# PyInstaller bundle
    if hasattr(sys, "_MEIPASS"):
        # onefile bundle
        BASE_DIR = sys._MEIPASS
    else:
        # onedir bundle
        BASE_DIR = os.path.dirname(sys.executable)
else:
    # Running as a normal script
    BASE_DIR = os.path.dirname(os.path.abspath(__file__))


# =========================
# Setup
# =========================
class LimitUploadSizeMiddleware(BaseHTTPMiddleware):
    def __init__(self, app, max_upload_size: int):
        super().__init__(app)
        self.max_upload_size = max_upload_size

    async def dispatch(self, request: Request, call_next):
        if request.method == "POST":
            content_length = request.headers.get("content-length")
            if content_length and int(content_length) > self.max_upload_size:
                return Response(content="File too large", status_code=413)
        return await call_next(request)

# =========================
# Logging Setup
# =========================
if sys.platform == "win32":
    LOG_DIR = os.path.join(os.getenv("LOCALAPPDATA", BASE_DIR), "paiassistant", "logs")
else:
    LOG_DIR = os.path.expanduser("~/.paiassistant/logs")

os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "pai_log.txt")

LOG_FILE = os.path.join(LOG_DIR, "pai_log.txt")

logger = logging.getLogger()
logger.setLevel(logging.INFO)

formatter = logging.Formatter("%(asctime)s [%(levelname)s] %(message)s")

# Log to file
file_handler = RotatingFileHandler(LOG_FILE, maxBytes=5*1024*1024, backupCount=3, encoding="utf-8")
file_handler.setFormatter(formatter)
logger.addHandler(file_handler)

# Also log to console for early debugging
console_handler = logging.StreamHandler(sys.stdout)
console_handler.setFormatter(formatter)
logger.addHandler(console_handler)

logger.info(f"BASE_DIR = {BASE_DIR}")
logger.info(f"LOG_DIR = {LOG_DIR}")

app = FastAPI()
app.add_middleware(LimitUploadSizeMiddleware, max_upload_size=500 * 1024 * 1024)  # 500 MB

api_key = os.getenv("OPENAI_API_KEY")

if api_key:
    client = OpenAI(api_key=api_key)
else:
    client = None
    print("OPENAI_API_KEY is missing. OpenAI features will be disabled.")

# ✅ Qdrant server mode instead of embedded mode
QDRANT_URL = "http://127.0.0.1:6333"
qdrant = qdrant_client.QdrantClient(url=QDRANT_URL)

COLLECTION_NAME = "docs"

# Ensure collection exists
try:
    qdrant.recreate_collection(
        collection_name=COLLECTION_NAME,
        vectors_config=models.VectorParams(size=1536, distance=models.Distance.COSINE)
    )
except Exception as e:
    logging.error(f"Error initializing Qdrant: {e}")

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# =========================
# Shutdown hook
# =========================
@app.on_event("shutdown")
def shutdown_event():
    try:
        qdrant.close()
        logger.info("Qdrant client closed cleanly.")
    except Exception as e:
        logging.error(f"Error while closing Qdrant: {e}")

# =========================
# Helpers
# =========================
def chunk_pdf(file_path, chunk_size=500):
    """Read PDF and return list of text chunks."""
    doc = fitz.open(file_path)
    text = ""
    for page in doc:
        text += page.get_text("text") + "\n"
    doc.close()

    words = text.split()
    chunks = []
    for i in range(0, len(words), chunk_size):
        chunks.append(" ".join(words[i:i + chunk_size]))
    return chunks

def chunk_pdf_pages(file_path, chunk_size=500):
    """Read PDF page-by-page and split text into chunks of ~chunk_size words."""
    doc = fitz.open(file_path)
    chunks = []
    buffer = []
    word_count = 0

    for page in doc:
        text = page.get_text("text")
        words = text.split()
        buffer.extend(words)
        word_count += len(words)

        while word_count >= chunk_size:
            chunks.append(" ".join(buffer[:chunk_size]))
            buffer = buffer[chunk_size:]
            word_count = len(buffer)

    if buffer:
        chunks.append(" ".join(buffer))
    doc.close()
    return chunks

# =========================
# Endpoints
# =========================
@app.post("/upload")
async def upload(file: UploadFile = File(...), embedding_model: str = Form("text-embedding-3-small")):
    save_dir = "temp"
    os.makedirs(save_dir, exist_ok=True)
    file_path = os.path.join(save_dir, file.filename)
    if client is None:
    # Optionally raise a RuntimeError if a critical operation is attempted
        raise RuntimeError("OPENAI_API_KEY is missing. Cannot perform this action.")

    try:
        logger.info(f"Received upload request: {file.filename}, model={embedding_model}")
        with open(file_path, "wb") as f:
            while chunk := await file.read(1024*1024):
                f.write(chunk)

        print(f"[INFO] File saved to {file_path}")
        chunks = chunk_pdf_pages(file_path)
        print(f"[INFO] {len(chunks)} chunks generated from {file.filename}")

        for idx, chunk in enumerate(chunks, 1):
            print(f"[INFO] Embedding + adding chunk {idx}/{len(chunks)}")
            embedding = client.embeddings.create(
                model=embedding_model,
                input=chunk
            ).data[0].embedding

            qdrant.upsert(
                collection_name=COLLECTION_NAME,
                points=[
                    models.PointStruct(
                        id=str(uuid.uuid4()),
                        vector=embedding,
                        payload={"text": chunk, "file": file.filename}
                    )
                ]
            )

        print(f"[INFO] Completed processing {file.filename}")
        logger.info(f"Generated {len(chunks)} chunks for {file.filename}")
        for i, chunk in enumerate(chunks, 1):
            logger.info(f"Chunk {i}: {chunk[:100]}...")
        return {"status": "success", "chunks": len(chunks)}

    except Exception as e:
        print(f"[ERROR] {e}")
        logging.error(f"Error uploading {file.filename}: {str(e)}")
        return JSONResponse(status_code=500, content={"error": str(e)})

@app.post("/ask")
async def ask(
    query: str = Form(...),
    answer_model: str = Form("gpt-4o-mini"),
    embedding_model: str = Form("text-embedding-3-small")
):
    if client is None:
    # Optionally raise a RuntimeError if a critical operation is attempted
        raise RuntimeError("OPENAI_API_KEY is missing. Cannot perform this action.")
    try:
        logger.info(f"Received query: {query} (model={answer_model})")
        # 1️⃣ Embed the query
        query_embedding = client.embeddings.create(
            model=embedding_model,
            input=query
        ).data[0].embedding

        # 2️⃣ Search Qdrant
        response = qdrant.query_points(
            collection_name=COLLECTION_NAME,
            query=query_embedding,
            limit=3
        )

        results = response.points  

        # 3️⃣ If no results, return strict response
        if not results or len(results) == 0:
            return {
                "answer": "No relevant information found in your documents. Did you upload the correct file?",
                "answer_model": answer_model,
                "embedding_model": embedding_model
            }

        # 4️⃣ Combine retrieved text
        context = " ".join([r.payload["text"] for r in results])    

        if not context.strip():
            return {
                "answer": "No relevant information found in your documents.",
                "answer_model": answer_model,
                "embedding_model": embedding_model
            }

        # 5️⃣ Strict system prompt to prevent hallucination
        system_prompt = (
            "You are PAI, a helpful assistant. "
            "You must only answer using the provided context. "
            "If the answer is not in the context, say: "
            "'I don’t know. Please upload a document that contains this information or try a different answer model. Did you type names correctly?'"
        )

        # 6️⃣ Generate answer using only context
        completion = client.chat.completions.create(
            model=answer_model,
            messages=[
                {"role": "system", "content": system_prompt},
                {"role": "user", "content": f"Context: {context}\n\nQuestion: {query}"}
            ]
        )

        answer = completion.choices[0].message.content.strip()
        logger.info(f"Generated answer for query '{query}': {answer[:100]}...")

        return {
            "answer": answer,
            "answer_model": answer_model,
            "embedding_model": embedding_model
        }

    except Exception as e:
        print(f"[ERROR] {e}")
        logging.error(f"Error processing query '{query}': {str(e)}")
        return JSONResponse(status_code=500, content={"error": str(e)})



@app.post("/clear")
async def clear_collection():
    """
    Deletes all points in the collection and recreates it.
    """
    try:
        qdrant.delete_collection(COLLECTION_NAME)
        qdrant.recreate_collection(
            collection_name=COLLECTION_NAME,
            vectors_config=models.VectorParams(size=1536, distance=models.Distance.COSINE)
        )
        return {"status": "Collection cleared and recreated."}
    except Exception as e:
        logging.error(f"Error clearing collection: {str(e)}")
        return {"error": str(e)}
    
LOG_DIR = os.path.join(os.getenv("LOCALAPPDATA", "."), "paiassistant", "logs")
LOG_FILE = os.path.join(LOG_DIR, "pai_log.txt")

@app.get("/logs", response_class=PlainTextResponse)
async def get_logs():
    try:
        if not os.path.exists(LOG_FILE):
            return "No log file found."
        with open(LOG_FILE, "r", encoding="utf-8", errors="ignore") as f:
            return f.read()
    except Exception as e:
        logger.error(f"Error reading logs: {e}")
        return PlainTextResponse(f"Error reading logs: {e}", status_code=500)
    
from fastapi import BackgroundTasks

@app.post("/shutdown")
async def shutdown(request: Request, background_tasks: BackgroundTasks):
    """Gracefully shut down backend (including Qdrant)."""
    def stopper():
        logger.info("Received shutdown request, stopping backend...")
        print("[INFO] Backend shutting down via /shutdown")
        server = request.app.state.server
        server.should_exit = True

    background_tasks.add_task(stopper)
    return {"status": "shutting down"}

frontend_path = os.path.join(BASE_DIR, "frontend")
app.mount("/", StaticFiles(directory=frontend_path, html=True), name="frontend")



if __name__ == "__main__":
    import uvicorn
    config = uvicorn.Config(app, host="127.0.0.1", port=8000, reload=False)
    server = uvicorn.Server(config)
    app.state.server = server
    server.run()