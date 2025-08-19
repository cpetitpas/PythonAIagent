import os
import uuid
import asyncio
from fastapi import FastAPI, UploadFile, BackgroundTasks
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware
import chromadb
from openai import OpenAI
from PyPDF2 import PdfReader

# -----------------------------
# Setup clients
# -----------------------------
client = OpenAI()

# 🚨 Ephemeral (in-memory, no disk persistence)
chroma_client = chromadb.EphemeralClient()
collection = chroma_client.get_or_create_collection("my_collection")

STATUS = {}

# -----------------------------
# Helpers
# -----------------------------
def extract_pdf_text(file_path: str) -> str:
    reader = PdfReader(file_path)
    return " ".join(page.extract_text() or "" for page in reader.pages)

def chunk_text(text: str, max_tokens=400, overlap=50):
    words = text.split()
    chunks = []
    for i in range(0, len(words), max_tokens - overlap):
        chunk = " ".join(words[i:i + max_tokens])
        if chunk:
            chunks.append(chunk)
    return chunks

def embed_with_retry(text: str):
    response = client.embeddings.create(
        model="text-embedding-3-small",
        input=text
    )
    return response.data[0].embedding

# -----------------------------
# Background embedding job
# -----------------------------
async def process_file_and_embed(file_path: str, filename: str):
    global collection
    STATUS[filename] = {"status": "processing", "chunks": 0}
    try:
        text = extract_pdf_text(file_path)
        chunks = chunk_text(text, max_tokens=400, overlap=50)
        print(f"[INFO] {len(chunks)} chunks generated from {filename}")

        loop = asyncio.get_running_loop()
        embeddings = []

        for i, chunk in enumerate(chunks):
            emb = await loop.run_in_executor(None, embed_with_retry, chunk)
            embeddings.append(emb)
            STATUS[filename]["chunks"] = i + 1
            print(f"[INFO] Embedded chunk {i+1}/{len(chunks)}")

        # 🚨 In-memory add (no SQLite locking)
        collection.upsert(
            documents=chunks,
            metadatas=[{"source": filename}] * len(chunks),
            ids=[f"{filename}_{i}_{uuid.uuid4().hex[:8]}" for i in range(len(chunks))],
            embeddings=embeddings
        )

        STATUS[filename]["status"] = "done"
        print(f"[INFO] Completed processing {filename}")

    except Exception as e:
        print(f"[ERROR] {e}")
        STATUS[filename] = {"status": "error", "error": str(e)}

    finally:
        try:
            os.remove(file_path)
        except FileNotFoundError:
            pass

# -----------------------------
# FastAPI endpoints
# -----------------------------
app = FastAPI()

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # relax in dev
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

@app.post("/upload")
async def upload(file: UploadFile, background_tasks: BackgroundTasks):
    file_path = f"./{file.filename}"
    with open(file_path, "wb") as f:
        f.write(await file.read())

    background_tasks.add_task(process_file_and_embed, file_path, file.filename)
    return JSONResponse(content={"status": "uploaded"})

@app.get("/status/{filename}")
async def status(filename: str):
    return STATUS.get(filename, {"status": "unknown"})
