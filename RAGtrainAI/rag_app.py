import os
import fitz  # PyMuPDF for PDF reading
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from openai import OpenAI
import qdrant_client
from qdrant_client.http import models
import uuid
from starlette.middleware.base import BaseHTTPMiddleware
from starlette.requests import Request
from starlette.responses import Response

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

app = FastAPI()
app.add_middleware(LimitUploadSizeMiddleware, max_upload_size=500 * 1024 * 1024)  # 500 MB
openai_api_key = os.getenv("OPENAI_API_KEY")
client = OpenAI(api_key=openai_api_key)

# Qdrant client
qdrant = qdrant_client.QdrantClient(host="qdrant", port=6333)
COLLECTION_NAME = "docs"

# Ensure collection exists
qdrant.recreate_collection(
    collection_name=COLLECTION_NAME,
    vectors_config=models.VectorParams(size=1536, distance=models.Distance.COSINE)
)

# CORS
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # restrict to frontend domain if needed
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

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

    try:
        # Stream file to disk in 1MB chunks
        with open(file_path, "wb") as f:
            while chunk := await file.read(1024*1024):
                f.write(chunk)

        print(f"[INFO] File saved to {file_path}")

        # Process PDF page by page
        chunks = chunk_pdf_pages(file_path)
        print(f"[INFO] {len(chunks)} chunks generated from {file.filename}")

        # Embed + store in Qdrant
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
        return {"status": "success", "chunks": len(chunks)}

    except Exception as e:
        print(f"[ERROR] {e}")
        return JSONResponse(status_code=500, content={"error": str(e)})


@app.post("/ask")
async def ask(
    query: str = Form(...),
    answer_model: str = Form("gpt-4o-mini"),
    embedding_model: str = Form("text-embedding-3-small")
):
    try:
        # Embed query
        query_embedding = client.embeddings.create(
            model=embedding_model,
            input=query
        ).data[0].embedding

        # Search Qdrant
        results = qdrant.search(
            collection_name=COLLECTION_NAME,
            query_vector=query_embedding,
            limit=3
        )

        context = " ".join([r.payload["text"] for r in results])

        # Generate answer
        completion = client.chat.completions.create(
            model=answer_model,
            messages=[
                {"role": "system", "content": "You are a helpful assistant using retrieved context."},
                {"role": "user", "content": f"Context: {context}\n\nQuestion: {query}"}
            ]
        )

        answer = completion.choices[0].message.content
        return {
            "answer": answer,
            "answer_model": answer_model,
            "embedding_model": embedding_model
        }

    except Exception as e:
        print(f"[ERROR] {e}")
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
        return {"error": str(e)}
