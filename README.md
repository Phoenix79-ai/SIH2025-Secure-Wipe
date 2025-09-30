# 🔐 Secure Data Wiping for Trustworthy IT Asset Recycling
**Smart India Hackathon 2025 – PS ID: SIH25070**  
Ministry of Mines · JNARDDC  

---

## 📌 Problem Statement
India generates over **1.75 million tonnes of e-waste annually**, but fear of data breaches prevents users from recycling old laptops, smartphones, and drives.  
Existing tools are either **too expensive, too complex, or unverifiable**.  

We designed a **secure, open-source, cross-platform data wiping solution** that:
- Securely erases **all storage areas** (including hidden HPA/DCO, SSD reserved blocks).
- Generates **digitally signed wipe certificates** in PDF + JSON.
- Provides an **intuitive one-click interface**.
- Works **offline via bootable ISO/USB**.
- Aligns with **NIST SP 800-88 standards**.

---

## ⚙️ Features
- **Multi-layered Wipe Logic**  
  - ATA Secure Erase (via `hdparm`)  
  - NVMe Sanitize (via `nvme-cli`)  
  - Fallback: `shred` + `dd` overwrite (multiple passes)  
  - Automatic retries (up to 10 times if hardware blocks requests)

- **Hidden Area Support**  
  - Detects and unlocks **HPA/DCO regions** before wiping.

- **Cryptographic Proof**  
  - Generates **tamper-proof wipe certificates** (PDF + JSON).  
  - Signed with SHA-256 checksum for verification.

- **Cross-Platform**  
  - Linux (native)  
  - Windows (via WSL / bootable ISO)  
  - Android (via Termux / bootable USB image)

- **User Experience**  
  - Simple **one-click execution**.  
  - Clear warnings before irreversible operations.  
  - **Offline usable** (bootable ISO/USB mode).

---

## 🛠️ Usage
> ⚠️ **Warning:** This operation is irreversible. All data will be destroyed.  
> Run only on test devices or with explicit permission.

1. Clone repo & give execution permission:

   bash:
   git clone https://github.com/Phoenix79-ai/SIH2025-Secure-Wipe.git
   cd SIH2025-Secure-Wipe/core
   chmod +x secure_erase.sh
   
2. Run secure erase:

   bash:
   sudo ./secure_erase.sh /dev/sdX        #X -> refers to your disk number
   
3. On success/failure certificate is generated :

   core/Certificates/
    ├── wipe_report_<device>.pdf
    └── wipe_report_<device>.json

🎥 Demo

👉 https://youtu.be/QGy0Fnvha2w 

📊 Comparison (DBAN vs Blancco vs Our Tool)

DBAN: Free, but outdated & no proof of erasure.

Blancco: Enterprise, closed-source, costly license.

Ours: Open-source, standards-compliant, generates verifiable certificates.

📜 Standards & Compliance

Aligned with NIST SP 800-88 Rev.1 – Guidelines for Media Sanitization.
Includes certificate for third-party auditing.

👨‍💻 Team

Role: Core Developer – Secure Wipe & Verification

Team Focus: Open-source solution that matches/blends security, transparency, and usability.

🌍 Impact

Encourages trustworthy recycling of IT assets.
Reduces hoarding of electronics worth ₹50,000+ crore.
Supports India’s circular economy and e-waste management efforts.

📧 Contact

For queries or collaboration:
📩 srijandas008@gmail.com

