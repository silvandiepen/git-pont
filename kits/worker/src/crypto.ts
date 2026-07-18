/**
 * WebCrypto helpers: AES-GCM encryption of credentials at rest, and opaque
 * random id generation for sessions and OAuth state.
 */

const IV_BYTES = 12;

function base64ToBytes(base64: string): Uint8Array {
  const binary = atob(base64);
  const bytes = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i += 1) bytes[i] = binary.charCodeAt(i);
  return bytes;
}

function bytesToBase64(bytes: Uint8Array): string {
  let binary = "";
  const chunk = 0x8000;
  for (let i = 0; i < bytes.length; i += chunk) {
    binary += String.fromCharCode(...bytes.subarray(i, i + chunk));
  }
  return btoa(binary);
}

/** Copy a view into a fresh `ArrayBuffer` so WebCrypto's `BufferSource` is satisfied. */
function toArrayBuffer(view: Uint8Array): ArrayBuffer {
  const copy = new Uint8Array(view.byteLength);
  copy.set(view);
  return copy.buffer;
}

async function importKey(encKeyBase64: string): Promise<CryptoKey> {
  const raw = base64ToBytes(encKeyBase64);
  if (raw.length !== 32) {
    throw new Error("GITPONT_ENC_KEY must be a base64-encoded 32-byte key");
  }
  return crypto.subtle.importKey("raw", toArrayBuffer(raw), { name: "AES-GCM" }, false, [
    "encrypt",
    "decrypt",
  ]);
}

/** Encrypt a JSON-serializable value; returns `base64(iv).base64(ciphertext)`. */
export async function encryptJSON(encKeyBase64: string, value: unknown): Promise<string> {
  const key = await importKey(encKeyBase64);
  const iv = crypto.getRandomValues(new Uint8Array(IV_BYTES));
  const plaintext = new TextEncoder().encode(JSON.stringify(value));
  const ciphertext = new Uint8Array(
    await crypto.subtle.encrypt({ name: "AES-GCM", iv: toArrayBuffer(iv) }, key, toArrayBuffer(plaintext)),
  );
  return `${bytesToBase64(iv)}.${bytesToBase64(ciphertext)}`;
}

/** Decrypt a value produced by {@link encryptJSON}. */
export async function decryptJSON<T>(encKeyBase64: string, payload: string): Promise<T> {
  const [ivPart, dataPart] = payload.split(".");
  if (!ivPart || !dataPart) throw new Error("Malformed encrypted payload");
  const key = await importKey(encKeyBase64);
  const iv = base64ToBytes(ivPart);
  const ciphertext = base64ToBytes(dataPart);
  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv: toArrayBuffer(iv) },
    key,
    toArrayBuffer(ciphertext),
  );
  return JSON.parse(new TextDecoder().decode(plaintext)) as T;
}

/** Cryptographically-random opaque id (hex). */
export function randomId(bytes = 32): string {
  const buffer = crypto.getRandomValues(new Uint8Array(bytes));
  return [...buffer].map((b) => b.toString(16).padStart(2, "0")).join("");
}
