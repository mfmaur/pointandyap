// The page's half of the crypto (Sources/PointAndYap/Links.swift is the Mac's). No DOM: tests import it in Node.
const enc = new TextEncoder();

export function unb64url(s) {
  const b = atob(s.replace(/-/g, "+").replace(/_/g, "/") + "===".slice((s.length + 3) % 4));
  return Uint8Array.from(b, (c) => c.charCodeAt(0));
}

export function b64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

/** The screenshots: AES-256-GCM, 12-byte nonce first, "pointandyap tour <id>" as AAD. */
export async function openTour(blob, linkKey, id) {
  const key = await crypto.subtle.importKey("raw", linkKey, "AES-GCM", false, ["decrypt"]);
  const plain = await crypto.subtle.decrypt({ name: "AES-GCM", iv: blob.slice(0, 12), additionalData: enc.encode(`pointandyap tour ${id}`) },
    key, blob.slice(12));
  return JSON.parse(new TextDecoder().decode(plain));
}

/** Feedback, sealed to the owner's Mac: a one-time P-256 key, ECDH, HKDF-SHA256 (salt: link key), AES-256-GCM. */
export async function sealFeedback(obj, ownerKeyB64, linkKey, id) {
  const owner = await crypto.subtle.importKey("raw", Uint8Array.from(atob(ownerKeyB64), (c) => c.charCodeAt(0)),
    { name: "ECDH", namedCurve: "P-256" }, false, []);
  const eph = await crypto.subtle.generateKey({ name: "ECDH", namedCurve: "P-256" }, false, ["deriveBits"]);
  const epk = new Uint8Array(await crypto.subtle.exportKey("raw", eph.publicKey));
  const shared = await crypto.subtle.deriveBits({ name: "ECDH", public: owner }, eph.privateKey, 256);
  const hk = await crypto.subtle.importKey("raw", shared, "HKDF", false, ["deriveKey"]);
  const key = await crypto.subtle.deriveKey({ name: "HKDF", hash: "SHA-256", salt: linkKey, info: enc.encode(`pointandyap feedback ${id}`) },
    hk, { name: "AES-GCM", length: 256 }, false, ["encrypt"]);
  const iv = crypto.getRandomValues(new Uint8Array(12));
  const ct = new Uint8Array(await crypto.subtle.encrypt({ name: "AES-GCM", iv, additionalData: epk }, key, enc.encode(JSON.stringify(obj))));
  const out = new Uint8Array(epk.length + 12 + ct.length);
  out.set(epk); out.set(iv, epk.length); out.set(ct, epk.length + 12);
  return out;
}
