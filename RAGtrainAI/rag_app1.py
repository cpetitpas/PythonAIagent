import os
from fastapi import FastAPI, File, UploadFile, Form
from fastapi.responses import JSONResponse
from pypdf import PdfReader
import chromadb
from langchain.text_splitter import RecursiveCharacterTextSplitter
from openai import OpenAI

# --- CONFIG ---
OPENAI_API_KEY = os.getenv("OPENAI_API_KEY")
if not OPENAI_API_KEY:
    raise ValueError("Please set your OPENAI_API_KEY environment variable.")

# Create the OpenAI client once, at startup
client = OpenAI(api_key=OPENAI_API_KEY)


# Vector DB (Chroma runs locally by default)
chroma_client = chromadb.Client()
collection = chroma_client.create_collection("docs")

# FastAPI app
app = FastAPI()

# Utility: extract text from PDF
def extract_pdf_text(file_path):
    reader = PdfReader(file_path)
    text = ""
    for page in reader.pages:
        text += page.extract_text() or ""
    return text

# Utility: chunk text
def chunk_text(text, chunk_size=500, overlap=50):
    splitter = RecursiveCharacterTextSplitter(chunk_size=chunk_size, chunk_overlap=overlap)
    return splitter.split_text(text)

# --- ENDPOINTS ---

@app.post("/upload")
async def upload_file(file: UploadFile = File(...)):
    file_path = f"temp_{file.filename}"
    with open(file_path, "wb") as f:
        f.write(await file.read())

    text = extract_pdf_text(file_path)
    chunks = chunk_text(text)

    for i, chunk in enumerate(chunks):
        emb = client.embeddings.create(
            model="text-embedding-3-small",
            input=chunk
        ).data[0].embedding

        collection.add(
            documents=[chunk],
            metadatas=[{"source": file.filename}],
            ids=[f"{file.filename}_{i}"],
            embeddings=[emb]
        )

    os.remove(file_path)
    return {"status": "success", "chunks_added": len(chunks)}

@app.post("/ask")
async def ask_question(question: str = Form(...)):
    q_emb = client.embeddings.create(
        model="text-embedding-3-small",
        input=question
    ).data[0].embedding

    results = collection.query(query_embeddings=[q_emb], n_results=3)
    context = "\n".join(results["documents"][0])

    prompt = f"Answer based on the context below:\n{context}\n\nQuestion: {question}"
    answer = client.chat.completions.create(
        model="gpt-4o",
        messages=[{"role": "user", "content": prompt}]
    )

    return JSONResponse({"answer": answer.choices[0].message["content"]})

# Run with: uvicorn rag_app:app --reload
