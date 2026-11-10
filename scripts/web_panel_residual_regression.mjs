#!/usr/bin/env node
// P2.13: execute the exact embedded production JS; only DOM and API I/O are mocked.
import assert from 'node:assert/strict';
import { readFileSync } from 'node:fs';
import vm from 'node:vm';

const source = readFileSync(new URL('../rust-server/web_panel.rs', import.meta.url), 'utf8');

function between(text, startMarker, endMarker, includeStart = false) {
    const start = text.indexOf(startMarker);
    assert.notEqual(start, -1, `Missing production marker: ${startMarker}`);
    const end = text.indexOf(endMarker, start + startMarker.length);
    assert.notEqual(end, -1, `Missing production marker: ${endMarker}`);
    return text.slice(includeStart ? start : start + startMarker.length, end);
}

const panel = between(source, 'const PANEL_HTML_TEMPLATE: &str = r##"', '\n"##;');
const ipsJs = between(panel, '        let templateIpsCache =',
    '        async function deleteRoutingRule(', true);
const escJs = panel.match(/^        const esc = .+;$/m)?.[0];
assert.ok(escJs, 'Missing production esc helper');
const productionJs = `${escJs}\n${ipsJs}`;

function harness(responses) {
    const elements = new Map([
        ['templateIpsList', { innerHTML: '' }],
        ['templateIpsCount', { textContent: '' }],
        ['templateIpsFilter', { value: 'stale filter' }],
        ['templateIpsDlg', {
            open: false,
            opens: 0,
            showModal() {
                assert.equal(this.open, false, 'Close the dialog before reopening');
                this.open = true;
                this.opens += 1;
            },
            close() { this.open = false; },
        }],
    ]);
    const calls = [];
    const context = vm.createContext({
        document: {
            getElementById(id) {
                assert.ok(elements.has(id), `Unexpected DOM access: ${id}`);
                return elements.get(id);
            },
        },
        async api(path) {
            calls.push(path);
            assert.equal(path, '/api/template-ips');
            assert.ok(responses.length, 'Unexpected fetch after successful caching');
            const response = responses.shift();
            if (response instanceof Error) throw response;
            return response;
        },
    });
    vm.runInContext(productionJs, context, { filename: 'web_panel.rs:templateIps' });
    return {
        elements,
        calls,
        run: code => vm.runInContext(code, context),
        cache: () => vm.runInContext('templateIpsCache', context),
        async open() {
            elements.get('templateIpsDlg').close();
            await vm.runInContext('openTemplateIpsDlg()', context);
        },
    };
}

for (const [label, failure] of [
    ['HTTP failure', { ok: false, text: async () => { throw new Error('Must not read an error body'); } }],
    ['network failure', new Error('connection reset')],
    ['response-body failure', { ok: true, text: async () => { throw new Error('body interrupted'); } }],
]) {
    const h = harness([failure, {
        ok: true,
        text: async () => ' # comment\n 10.0.0.0/8 \n\n192.168.0.0/16\n',
    }]);

    await h.open();
    assert.equal(h.calls.length, 1, label);
    assert.equal(h.cache(), null, `${label} must remain uncached`);
    assert.equal(h.elements.get('templateIpsCount').textContent, '—', label);
    assert.match(h.elements.get('templateIpsList').innerHTML, /Не удалось загрузить/, label);

    h.elements.get('templateIpsFilter').value = 'old filter';
    await h.open();
    assert.equal(h.calls.length, 2, `${label}: reopen must retry`);
    assert.deepEqual(Array.from(h.cache()), ['10.0.0.0/8', '192.168.0.0/16']);
    assert.equal(h.elements.get('templateIpsCount').textContent, 2);
    assert.equal(h.elements.get('templateIpsFilter').value, '');
    assert.match(h.elements.get('templateIpsList').innerHTML, /10\.0\.0\.0\/8/);
    assert.match(h.elements.get('templateIpsList').innerHTML, /192\.168\.0\.0\/16/);

    h.run("filterTemplateIps('192.168')");
    assert.doesNotMatch(h.elements.get('templateIpsList').innerHTML, /10\.0\.0\.0\/8/);
    await h.open();
    assert.equal(h.calls.length, 2, 'Successful data must be cached for later opens');
    assert.equal(h.elements.get('templateIpsDlg').opens, 3);
    assert.match(h.elements.get('templateIpsList').innerHTML, /10\.0\.0\.0\/8/);
    console.log(`P2.13: ${label} -> cache=null -> reopen retries and loads 2 IPs -> third open cached (2 API calls)`);
}

const empty = harness([{ ok: true, text: async () => '# empty valid list\n\n' }]);
await empty.open();
assert.deepEqual(Array.from(empty.cache()), []);
assert.equal(empty.elements.get('templateIpsCount').textContent, 0);
assert.match(empty.elements.get('templateIpsList').innerHTML, /Ничего не найдено/);
await empty.open();
assert.equal(empty.calls.length, 1, 'A successful empty list is cacheable, unlike failure');
console.log('P2.13: successful empty list cached (1 API call across 2 opens)');

// C6: execute the production empty-list renderer with no clients and no groups.
// It must invite creating the first client instead of claiming there are no
// accesses, and must not throw before `loadClients()` has populated any data.
const renderMainClientsCardsJs = between(
    panel,
    '        function renderMainClientsCards() {',
    '\n        let clientsInFlight = false;',
    true,
);
const cardsJs = `${escJs}\n${renderMainClientsCardsJs}`;

{
    const cards = { innerHTML: '' };
    let presenceCalls = 0;
    const context = vm.createContext({
        window: { clientsData: [], groupsData: [] },
        document: {
            getElementById(id) {
                if (id === 'clientsCards') return cards;
                if (id === 'mainSearchInput') return null;
                throw new Error(`Unexpected DOM access: ${id}`);
            },
        },
        refreshPresenceBadges() { presenceCalls += 1; },
    });
    vm.runInContext(`${cardsJs}\nrenderMainClientsCards();`, context, {
        filename: 'web_panel.rs:renderMainClientsCards',
    });
    assert.match(
        cards.innerHTML,
        /Клиентов ещё нет\. Создайте первого клиента\./,
        'Empty list must guide the owner to create the first client',
    );
    assert.doesNotMatch(
        cards.innerHTML,
        /Нет созданных доступов\./,
        'Legacy "no accesses" wording must be gone',
    );
    assert.equal(presenceCalls, 1, 'Empty list still refreshes presence badges once');
    console.log('C6: empty client list renders the first-client invitation without throwing');
}
