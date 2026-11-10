// Custom elements the playground's Roc view renders.
//
// roc-signals hands a handler its event payload as text, read from the
// element's `value`, so each element sets `value` and dispatches a bubbling
// `change`.

// <docx-file>: a drop zone and file picker for one Word document. The
// payload is the file name, a line feed and the file's bytes as base64. The
// file input lives in a shadow root, so its own `change` never reaches the
// app's handler.
const MAX_BYTES = 32 * 1024 * 1024;

class DocxFile extends HTMLElement {
  connectedCallback() {
    if (this.shadowRoot) return;
    const root = this.attachShadow({ mode: "open" });
    root.innerHTML = `
      <style>
        label { display: grid; gap: .25rem; place-items: center; min-height: 9rem; padding: 1.5rem;
          border: 2px dashed var(--rule); border-radius: 10px; background: var(--panel); cursor: pointer;
          text-align: center; transition: border-color .15s, background .15s; }
        label:hover, label.over { border-color: var(--link); }
        label:focus-within { outline: 2px solid var(--link); outline-offset: 3px; }
        strong { font: 700 1.05rem "Merriweather", Georgia, serif; }
        span { color: var(--muted); font-size: .9rem; }
        input { position: absolute; opacity: 0; width: 1px; height: 1px; }
      </style>
      <label part="zone">
        <input type="file" accept=".docx,application/vnd.openxmlformats-officedocument.wordprocessingml.document">
        <strong>Drop a .docx here</strong>
        <span>or click to choose one · up to 32 MB</span>
      </label>`;
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

// <now-clock>: the time the page opened, as a W3C date and time. roc-docx
// reads no clock, so the dates of review edits and generated letters come
// from here.
class NowClock extends HTMLElement {
  connectedCallback() {
    this.hidden = true;
    this.value = new Date().toISOString().replace(/\.\d+Z$/, "Z");
    queueMicrotask(() => this.dispatchEvent(new Event("change", { bubbles: true })));
  }
}

customElements.define("docx-file", DocxFile);
customElements.define("now-clock", NowClock);
