#!/usr/bin/env python
import io
import numpy as np

def load_vectors(fname):
    fin = io.open(fname, 'r', encoding='utf-8', newline='\n')
    n, d = map(int, fin.readline().split())
    data = {}
    i = 0
    for line in fin:
        tokens = line.rstrip().split(' ')
        data[tokens[0]] = list(map(float, tokens[1:]))
        i += 1
        if i % 1000 == 0:
            print(i)
    return data

def cosine_similarity(vec1, vec2):
    """
    Calculates the cosine similarity between two vectors.

    Args:
        vec1 (list or np.array): The first vector.
        vec2 (list or np.array): The second vector.

    Returns:
        float: The cosine similarity between the two vectors (ranging from -1 to 1).
               Returns None if either vector is zero or if a dimension mismatch occurs.
    """
    vec1 = np.array(vec1)
    vec2 = np.array(vec2)

    if vec1.shape != vec2.shape:
        raise ValueError("Vectors must have the same dimensions: " + str(vec1) + " " + str(vec2))

    if np.all(vec1 == 0) or np.all(vec2 == 0):
        return 0

    dot_product = np.dot(vec1, vec2)
    magnitude_vec1 = np.linalg.norm(vec1)
    magnitude_vec2 = np.linalg.norm(vec2)

    similarity = dot_product / (magnitude_vec1 * magnitude_vec2)
    return similarity

def print_similarity(vectors, word1, word2):
    if not word1 in vectors:
        raise ValueError("No embedding for " + word1)
    if not word2 in vectors:
        raise ValueError("No embedding for " + word2)
    vec1 = vectors[word1]
    vec2 = vectors[word2]
    print(word1 + " " + word2 + ": " + str(cosine_similarity(vec1, vec2)))
    
vectors = load_vectors('wiki-news-220k.vec')
print_similarity(vectors, 'cat', 'meow')
print_similarity(vectors, 'mow', 'lawn')
print_similarity(vectors, 'mow', 'mows')
print_similarity(vectors, 'mow', 'mowed')
print_similarity(vectors, 'mow', 'moll')
print_similarity(vectors, 'mow', 'mosh')
