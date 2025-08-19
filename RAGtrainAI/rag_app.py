import os
import fitz  # PyMuPDF for PDF reading
from fastapi import FastAPI, UploadFile, File, Form
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import JSONResponse
from openai import OpenAI
import qdrant_client
from qdrant_client.http import models
import uuid

# =========================
# Setup
# =========================
app = FastAPI()
client = OpenAI()

# Qdrant client
qdrant = qdrant_client.QdrantClient("localhost", port=6333)
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

    # Split into chunks
    words = text.split()
    chunks = []
    for i in range(0, len(words), chunk_size):
        chunks.append(" ".join(words[i:i+chunk_size]))
    return chunks

# =========================
# Endpoints
# =========================
@app.post("/upload")
async def upload(file: UploadFile = File(...)):
    save_dir = "temp"
    os.makedirs(save_dir, exist_ok=True)

    file_path = os.path.join(save_dir, file.filename)

    try:
        contents = await file.read()
        with open(file_path, "wb") as f:
            f.write(contents)

        print(f"[INFO] File saved to {file_path}")

        # Chunk PDF
        chunks = chunk_pdf(file_path)
        print(f"[INFO] {len(chunks)} chunks generated from {file.filename}")

        # Embed + store in Qdrant
        for idx, chunk in enumerate(chunks, 1):
            print(f"[INFO] Embedding + adding chunk {idx}/{len(chunks)}")

            embedding = client.embeddings.create(
                model="text-embedding-3-small",
                input=chunk
            ).data[0].embedding

            qdrant.upsert(
                collection_name=COLLECTION_NAME,
                points=[
                    models.PointStruct(
                        id=str(uuid.uuid4()),  # ✅ unique string ID
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
async def ask(query: str = Form(...)):
    try:
        # Embed query
        query_embedding = client.embeddings.create(
            model="text-embedding-3-small",
            input=query
        ).data[0].embedding

        # Search Qdrant
        results = qdrant.search(
            collection_name=COLLECTION_NAME,
            query_vector=query_embedding,
            limit=3
        )

        # Combine retrieved text for context
        context = " ".join([r.payload["text"] for r in results])

        # Generate answer
        completion = client.chat.completions.create(
            model="gpt-4o-mini",
            messages=[
                {"role": "system", "content": "You are a helpful assistant using retrieved context."},
                {"role": "user", "content": f"Context: {context}\n\nQuestion: {query}"}
            ]
        )

        answer = completion.choices[0].message.content
        return {"answer": answer}  # ✅ only return the answer

    except Exception as e:
        print(f"[ERROR] {e}")
        return JSONResponse(status_code=500, content={"error": str(e)})
