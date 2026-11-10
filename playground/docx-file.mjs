// <docx-file>: a drop zone and file picker for one Word document.
//
// roc-signals hands a handler its event payload as text, so the element
// reads the chosen file and dispatches a bubbling `change` whose payload,
// read from the element's `value`, is the file name, a line feed and the
// file's bytes as base64. The file input lives in a shadow root so its own
// `change` never reaches the app.
const MAX_BYTES = 32 * 1024 * 1024;

class DocxFile extends HTMLElement {
  connectedCallback() {
    if (this.shadowRoot) return;
    const root = this.attachShadow({ mode: "open" });
    root.innerHTML = `
      <style>
        label { display: block; border: 2px dashed #999; border-radius: 8px; padding: 1.5rem; text-align: center; cursor: pointer; }
        label.over { border-color: #2563eb; background: #eff6ff; }
        input { display: none; }
      </style>
      <label part="zone"><input type="file" accept=".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document">
        <span>Drop a .docx here, or click to choose one</span></label>`;
    const zone = root.querySelector("label");
    const input = root.querySelector("input");
    input.addEventListener("change", () => input.files[0] && this.load(input.files[0]));
    zone.addEventListener("dragover", (e) => { e.preventDefault(); zone.classList.add("over"); });
    zone.addEventListener("dragleave", () => zone.classList.remove("over"));
    zone.addEventListener("drop", (e) => {
      e.preventDefault();
      zone.classList.remove("over");
      const file = e.dataTransfer.files[0];
      if (file) this.load(file);
    });
  }

  async load(file) {
    if (file.size > MAX_BYTES) {
      this.value = `${file.name}\n!`;
    } else {
      const bytes = new Uint8Array(await file.arrayBuffer());
      let binary = "";
      for (let i = 0; i < bytes.length; i += 0x8000) binary += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
      this.value = `${file.name}\n${btoa(binary)}`;
    }
    this.dispatchEvent(new Event("change", { bubbles: true }));
  }
}

customElements.define("docx-file", DocxFile);
