from fastapi import FastAPI, UploadFile, Form
from fastapi.middleware.cors import CORSMiddleware
from PyPDF2 import PdfReader
from qdrant_client import QdrantClient
from qdrant_client.models import VectorParams, Distance
from openai import OpenAI
import os
import uuid

app = FastAPI()
# Allow all origins for development
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],  # In production, set this to your frontend's domain
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)

# Initialize clients
openai_client = OpenAI(api_key=os.getenv("OPENAI_API_KEY"))
qdrant = QdrantClient("localhost", port=6333)

COLLECTION_NAME = "docs"

# Ensure collection exists once at startup
if not qdrant.collection_exists(COLLECTION_NAME):
    qdrant.create_collection(
        collection_name=COLLECTION_NAME,
        vectors_config=VectorParams(size=1536, distance=Distance.COSINE)
    )
    print(f"[INFO] Created collection {COLLECTION_NAME}")
else:
    print(f"[INFO] Collection {COLLECTION_NAME} already exists")

@app.post("/upload")
async def upload(file: UploadFile):
    filename = file.filename
    print(f"[INFO] Received file {filename}")

    # Save uploaded file
    os.makedirs("temp", exist_ok=True)
    file_path = f"temp/{filename}"
    with open(file_path, "wb") as f:
        f.write(await file.read())

    # --- Step 1: Extract text ---
    reader = PdfReader(file_path)
    text = ""
    for page in reader.pages:
        page_text = page.extract_text()
        if page_text:
            text += page_text + "\n"

    if not text.strip():
        return {"error": "No extractable text found in PDF"}

    # --- Step 2: Split into chunks ---
    chunk_size = 500
    chunks = [text[i:i+chunk_size] for i in range(0, len(text), chunk_size)]
    print(f"[INFO] {len(chunks)} chunks generated from {filename}")

    # --- Step 3: Embed + upsert ---
    for i, chunk in enumerate(chunks):
        print(f"[INFO] Embedding chunk {i+1}/{len(chunks)}")
        embedding = openai_client.embeddings.create(
            model="text-embedding-3-small",
            input=chunk
        ).data[0].embedding

        point_id = str(uuid.uuid4())
        point = {
            "id": point_id,
            "vector": embedding,
            "payload": {"text": chunk, "source": filename},
        }

        print(f"[INFO] Upserting {point_id} into Qdrant…")
        qdrant.upsert(
            collection_name=COLLECTION_NAME,
            points=[point]
        )

    print(f"[INFO] Completed processing {filename}")
    return {"status": "Uploaded", "chunks_added": len(chunks)}

@app.post("/ask")
async def ask(query: str = Form(...)):
    print(f"[INFO] Received query: {query}")

    # Step 1: Embed query
    query_embedding = openai_client.embeddings.create(
        model="text-embedding-3-small",
        input=query
    ).data[0].embedding

    # Step 2: Search Qdrant for relevant chunks
    search_result = qdrant.search(
        collection_name=COLLECTION_NAME,
        query_vector=query_embedding,
        limit=3
    )

    if not search_result:
        return {"answer": "No relevant context found."}

    # Collect retrieved text
    context = "\n\n".join([hit.payload["text"] for hit in search_result])
    print(f"[INFO] Retrieved context:\n{context}")

    # Step 3: Use GPT to answer with context
    response = openai_client.chat.completions.create(
        model="gpt-4o-mini",
        messages=[
            {"role": "system", "content": "You are a helpful assistant. Use the provided context to answer."},
            {"role": "user", "content": f"Question: {query}\n\nContext:\n{context}"}
        ]
    )

    answer = response.choices[0].message.content
    print(f"[INFO] Answer: {answer}")

    return {"answer": answer}
