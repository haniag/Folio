// Rendering pipeline ported from markdown-live-preview (src/main.js):
// marked -> DOMPurify -> mermaid, rendered into #output.markdown-body.

(() => {
    const escapeHtml = (value) => value
        .replace(/&/g, '&amp;')
        .replace(/</g, '&lt;')
        .replace(/>/g, '&gt;')
        .replace(/"/g, '&quot;')
        .replace(/'/g, '&#39;');

    const createMarkedRenderer = () => {
        const renderer = new marked.Renderer();
        const renderCode = renderer.code.bind(renderer);

        renderer.code = (token) => {
            const lang = (token.lang || '').match(/^\S*/)?.[0].toLowerCase();
            if (lang !== 'mermaid') {
                return renderCode(token);
            }
            return `<pre class="mermaid">${escapeHtml(token.text)}</pre>\n`;
        };

        return renderer;
    };

    const renderMermaidDiagrams = async (outputElement) => {
        mermaid.initialize({
            startOnLoad: false,
            securityLevel: 'strict',
            theme: 'default',
            fontFamily: '"Aptos", -apple-system, Helvetica, Arial, sans-serif'
        });

        const elements = Array.from(outputElement.querySelectorAll('.mermaid'));
        for (const [index, element] of elements.entries()) {
            const source = element.textContent;
            try {
                const { svg } = await mermaid.render(`mermaid-${index}`, source);
                element.innerHTML = svg;
            } catch (error) {
                const message = error && error.message ? error.message : 'Unable to render Mermaid chart.';
                element.classList.add('mermaid-error');
                element.textContent = `Mermaid render error: ${message}`;
            }
        }
    };

    const waitForImages = (outputElement) => Promise.all(
        Array.from(outputElement.querySelectorAll('img'))
            .filter((img) => !img.complete)
            .map((img) => new Promise((resolve) => {
                img.addEventListener('load', resolve, { once: true });
                img.addEventListener('error', resolve, { once: true });
            }))
    );

    window.renderMarkdown = async (markdown) => {
        const outputElement = document.querySelector('#output');
        const html = marked.parse(markdown, {
            headerIds: false,
            mangle: false,
            renderer: createMarkedRenderer()
        });
        outputElement.innerHTML = DOMPurify.sanitize(html);
        // Load Aptos before mermaid measures label text and before printing.
        await document.fonts.load('400 12px "Aptos"');
        await document.fonts.load('700 12px "Aptos"');
        await renderMermaidDiagrams(outputElement);
        await waitForImages(outputElement);
        await document.fonts.ready;
        return true;
    };
})();
