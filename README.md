# mTLS Starter Kit

Interactive POSIX shell scripts for creating a private Certificate Authority (CA) and issuing X.509 client certificates for **mutual TLS (mTLS)**. Nginx examples are included; the certificate-generation scripts are not Nginx-specific.

## What is mTLS?

With ordinary HTTPS, a client verifies the server's TLS certificate. With **mTLS**, the server additionally requests a client certificate and verifies that the client controls the matching private key. This provides strong, passwordless authentication at the TLS layer.

**Advantages:** mutual authentication, no reusable client password, private keys are not sent over the network, and trust can be separated by CA.

**Trade-offs:** certificate issuance and renewal require administration; stolen client keys can impersonate their owner; revocation is **not** automated by this kit; client support varies; trusting a CA does not automatically implement per-user authorization. A valid client certificate is not sufficient if your application requires additional access controls.

## Cryptographic baseline (selected October 2026)

- **RSA 3072** for both CA and client keys by default (roughly 128-bit classical security; **not post-quantum**). The RSA key size can be changed in `config.sh`.
- **AES-256-CBC** protection is available for PEM private keys; protection of the CA key is recommended. Exported PKCS#12 files support an optional export password; using one is recommended.
- CA validity: **10 years** by default, configurable.
- Client validity: **2 years** by default, configurable and limited to the CA's remaining lifetime. A warning is shown above 2 years.
- CA certificate constraints: `CA:TRUE`, `keyCertSign`, `cRLSign`; client certificate constraints: `CA:FALSE`, `digitalSignature`, `clientAuth`.

These are choices made in **October 2026**, not a guarantee of indefinite security or compatibility. Review cryptographic recommendations and client/Nginx compatibility before creating long-lived CAs or upgrading TLS stacks. Client compatibility can vary; see the iOS note below.

## Requirements

- POSIX-compatible `/bin/sh`, common Unix utilities (`mktemp`, `date`, `chmod`, `mv`, `dirname`), and OpenSSL with RSA support and `openssl req -addext` (OpenSSL **1.1.1+**, OpenSSL 3.x recommended).
- An Nginx installation built against a compatible TLS library for the deployment example.
- Interactive terminal access. The scripts are **not designed for unattended automation**.
- Protect the checkout and generated `ca/` and `clients/` directories from unauthorized access. **Do not commit generated keys, PFX files, or CA archives to Git.**

## Workflows

### Standard: all-in-one provisioning

1. On a **TRUSTED machine**, run `./10-ca-create.sh` to create the CA under `ca/`.
2. On the **same TRUSTED machine**, run `./20-ca-provision-client.sh` to create or renew a named client certificate and PFX.
3. Copy **only `ca/ca.crt`** to the Nginx server and configure client certificate verification.
4. Transfer `clients/<name>/client.pfx` **securely** to the client and import it using the chosen export password (if any).

**Note:** standard provisioning generates `client.key` on the TRUSTED machine and leaves it in `clients/<name>/`. After securely transferring the PFX, decide whether to retain the local private key and PFX according to your backup policy. Deleting files does not guarantee secure erasure on SSDs or copy-on-write filesystems.

### Advanced: client retains its private key

1. **CLIENT machine:** `./30-adv-client-generate-csr.sh` → `client.key`, `client.csr`.
2. Transfer **only `client.csr`** to the TRUSTED machine.
3. **TRUSTED machine:** `./31-adv-ca-sign-client-csr.sh` → `client.crt`.
4. Transfer **only `client.crt`** back to the client machine.
5. **CLIENT machine:** `./32-adv-client-export-pkcs12.sh` → `client.pfx` (optional if the client can use the key and certificate directly).

In the advanced workflow, never transfer `client.key` to the CA. Never transfer `ca.key` to any client or verifying server. The CA operator must independently authorize requests: a cryptographically valid CSR does **not** establish the requester's identity.

## Script execution matrix

| Script | TRUSTED machine | Client machine | Nginx server |
|---|:---:|:---:|:---:|
| `10-ca-create.sh` | **Run** | — | — |
| `20-ca-provision-client.sh` | **Run** | — | — |
| `30-adv-client-generate-csr.sh` | — | **Run** | — |
| `31-adv-ca-sign-client-csr.sh` | **Run** | — | — |
| `32-adv-client-export-pkcs12.sh` | — | **Run** | — |

**TRUSTED machine** means the machine holding the CA private key and performing certificate issuance. It may be the Nginx host or a separate machine.

## File ownership and retention matrix

**Keep** = needed for continued operation or future issuance; **Optional** = may be retained for auditing, backups or re-export; **Temporary** = not needed after issuance; **Never** = should not be distributed to this role. The standard workflow temporarily creates client private-key material on the CA machine.

| File | TRUSTED machine | Client machine | Nginx server | Retention guidance |
|---|---|---|---|---|
| `ca/ca.key` | **Keep, secret** | Never | Never* | Keep securely for future issuance; offline storage is possible |
| `ca/ca.crt` | **Keep** | Optional | **Keep** | Public trust anchor; distribute to verifying servers |
| `client.key` | Created and retained (standard only) | **Keep, secret** | Never | Standard provisioning leaves a local copy; advanced provisioning keeps it on the client |
| `client.csr` | Temporary (advanced signing) | Temporary | Never | Disposable after successful issuance; optional audit copy |
| `client.crt` | **Keep** (managed copy) | **Keep** | Never | Public client certificate; the advanced workflow also writes a copy to the chosen output path |
| `client.pfx` | Created and retained (standard only) | Optional / **Keep securely** | Never | Contains private key; standard provisioning leaves a local copy |

*The Nginx server can also be the TRUSTED machine, in which case it holds `ca/ca.key`; keeping issuance separate is optional, not required. The client may receive `ca/ca.crt` for chain packaging or custom trust configuration, but never the CA private key. A verifying server normally needs the public CA certificate, not individual client private keys or certificates.

## One CA per installation and generated layout

One checkout manages **one CA** and multiple named clients. There is no CA selection. To manage multiple independent trust domains, use separate copies of this project.

```text
ca/
  ca.key
  ca.crt
  ca.srl
  backup/
    YYYY-MM-DD_HH-mm-ss_ca/
      ca.key
      ca.crt
      ca.srl                 # if present
clients/
  pc1/
    client.key
    client.csr
    client.crt
    client.pfx
  pc2/
    client.crt
  backup/
    YYYY-MM-DD_HH-mm-ss_pc1/
      client.key
      client.crt
    YYYY-MM-DD_HH-mm-ss_ca/
      pc1/
      pc2/
```

`backup` is a reserved client name. The tree is illustrative: some files may be absent (for example, the advanced workflow retains only `client.crt` on the TRUSTED machine). Archive names use timestamps with collision-safe suffixes.

### Replacement and archival

- **CA creation:** `10-ca-create.sh` creates `ca/ca.key` and `ca/ca.crt`.
- **CA replacement:** after an explicit warning and confirmation, the script generates and verifies a new CA, then archives the old CA files in `ca/backup/<generation>/` and **all active client directories** in `clients/backup/<same-generation>/`. The new CA requires reissuing clients and updating the public CA certificate on Nginx servers.
- **Client creation or renewal:** `20-ca-provision-client.sh` creates `clients/<name>/`. If the client already exists, it warns and asks for explicit confirmation. The replacement is generated and verified first; the old client directory is then archived in `clients/backup/<timestamp>_<name>/`.
- **Advanced CSR signing:** `31-adv-ca-sign-client-csr.sh` saves the signed certificate to the requested output path and retains a public copy under `clients/<name>/client.crt`. Reusing that name archives the old managed directory after confirmation. The client private key never needs to leave the client device.

Archives are **local history, not independent backups**. Back up secret material separately and protect archived keys/PFX as carefully as active keys. An archived or replaced certificate is **not revoked**: it may remain valid until expiry unless an external revocation or authorization policy rejects it.

There is no `clients.csv` issuance journal. Active and archived `.crt` files retain a **partial history** of managed client certificates. This is not a comprehensive issuance database: certificates issued and later deleted, or signing operations interrupted before the managed copy is saved, may not be represented. No revocation service is provided.

## Nginx configuration

Copy `ca/ca.crt` to a suitable location on the Nginx host, e.g. `/etc/nginx/mtls/ca.crt`:

```nginx
server {
    listen 443 ssl;
    server_name service.example.com;

    # Your normal HTTPS server certificate (independent of the client CA)
    ssl_certificate     /etc/nginx/tls/server.crt;
    ssl_certificate_key /etc/nginx/tls/server.key;

    # Client certificate authentication
    ssl_client_certificate /etc/nginx/mtls/ca.crt;
    ssl_verify_client on;
    ssl_verify_depth 1;

    location / {
        proxy_pass http://127.0.0.1:8080;
    }
}
```

Run `nginx -t` before reloading Nginx. `ssl_client_certificate` configures the trusted client CAs and advertises their names during the TLS handshake, helping clients select an appropriate certificate.\
Alternatively, `ssl_trusted_certificate` can be used to configure trust without advertising the accepted CA names. To trust multiple independent installations, combine their **public** CA PEM certificates into one bundle and reference that bundle.

A certificate's Common Name (CN) is its requested identity; Nginx exposes it as `$ssl_client_s_dn_cn`. If an application relies on the CN, explicitly configure the reverse proxy to pass it in a trusted header and ensure direct access to the upstream is blocked. **Do not trust identity headers supplied directly by external clients.** CN alone does not implement authorization.

## Certificate lifecycle and safety

- The CA key signs certificates; a separate Nginx server needs only the CA certificate to validate them. Protect and back up `ca/ca.key` securely.
- A certificate's validity period does not revoke it after device loss or compromise. This starter kit does **not** maintain a CRL or OCSP responder; remove the compromised CA from trusted server configurations, replace affected trust, or implement a separate revocation/access-control mechanism.
- Replacing a CA requires distributing the new `ca.crt` to every relevant server. The old CA is archived, **not** automatically deployed or trusted.
- Keep client private keys confidential; PFX files include private-key material and require careful handling.
- File permissions are restrictive, but a compromised machine can still expose its keys.
- The scripts are intended for simple, trusted environments, not as a full enterprise PKI.

## Troubleshooting

- **`unknown ca` / `certificate verify failed`**: check that Nginx trusts the CA that signed the client certificate.
- **`bad certificate`**: check client certificate EKU (`clientAuth`), key pairing, expiration and TLS implementation support.
- **No certificate presented**: verify client import and client-authentication algorithm compatibility.
- **CA replacement**: update the Nginx CA trust bundle and reissue client certificates as needed.
- **PKCS#12 import problems**: check the chosen PFX password (including whether the client accepts an empty password) and client-key algorithm compatibility.

## Cryptographic configuration and iOS compatibility

The toolkit **generates RSA keys only**. Set `RSA_BITS=3072` in `config.sh` (the default), or choose another RSA size of at least 2048 bits. Changes apply to *new* keys only. The advanced signing script can sign valid externally generated CSRs using other supported key algorithms; it does not generate those keys.

**PKCS#12 / iPhone:** Scripts `20` and `32` prompt twice for a PFX export password. An **empty password is allowed only after explicit confirmation**; it provides no password-based protection and may be rejected by some clients. In limited Safari/iOS testing (October 2026), imports of client identities using Ed25519 and EC P-256 keys failed, while an RSA client identity could be imported. These are environment-specific observations, **not** a claim that iOS universally rejects EC or Ed25519. A PFX may be readable by OpenSSL yet fail iOS enrollment. A non-empty PFX password protects the exported client identity; it is unrelated to the CA key passphrase.

## Optional certificate revocation lists (CRLs)

A **Certificate Revocation List (CRL)** can allow an Nginx server to reject a client certificate **before its expiry** without replacing the entire CA. CRLs are an optional, external lifecycle mechanism: this starter kit **does not generate, publish, update, or configure CRLs**.

CRLs require maintaining an accurate issuance/revocation record (which this kit does not provide), distributing a fresh signed list to every verifying server, and configuring the TLS verifier to check it (for example, Nginx's `ssl_crl` directive). Revocation is **not instantaneous**: enforcement depends on how quickly each server receives and reloads the updated list. An outdated, missing, or incorrectly configured CRL can leave revoked credentials usable or cause availability problems. A CRL also cannot undo a compromised CA signing key; CA replacement may still be necessary.

