from qdrant_client import QdrantClient
from qdrant_client.http import models as rest

client = QdrantClient(host="localhost", port=6333)

# This clears all points but keeps the collection definition
client.delete(
    collection_name="docs",
    points_selector=rest.FilterSelector(
        filter=rest.Filter(  # empty filter matches everything
            must=[]
        )
    )
)
