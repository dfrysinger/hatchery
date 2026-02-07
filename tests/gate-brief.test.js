const { test, describe } = require('node:test');
const assert = require('node:assert');
const fs = require('fs');
const path = require('path');
const { generateBrief, parseReports, fetchPRDescription, enforceWordLimit } = require('../scripts/generate-gate-brief');

describe('Gate Brief Generator', () => {
  describe('parseReports', () => {
    test('parses single report file', () => {
      const mockReport = `# Round 1 Report — Claude
## Topic: Authentication

## Executive Summary
- OAuth2 implementation complete
- Tests passing
- Security review needed

## Analysis
### Critical
- Rate limiting required

## Considerations
Trade-off between UX and security.

## Open Questions
Should we support social login?`;

      const tempFile = path.join(__dirname, 'temp-report.md');
      fs.writeFileSync(tempFile, mockReport);

      const reports = parseReports([tempFile]);
      
      assert.strictEqual(reports.length, 1);
      assert.ok(reports[0].includes('OAuth2 implementation'));
      assert.ok(reports[0].includes('Rate limiting required'));

      fs.unlinkSync(tempFile);
    });

    test('parses multiple report files', () => {
      const report1 = `# Round 1 Report — Claude\n## Summary\nFeature A complete`;
      const report2 = `# Round 1 Report — ChatGPT\n## Summary\nFeature B needs work`;

      const tempFile1 = path.join(__dirname, 'temp-report-1.md');
      const tempFile2 = path.join(__dirname, 'temp-report-2.md');
      
      fs.writeFileSync(tempFile1, report1);
      fs.writeFileSync(tempFile2, report2);

      const reports = parseReports([tempFile1, tempFile2]);
      
      assert.strictEqual(reports.length, 2);
      assert.ok(reports[0].includes('Feature A complete'));
      assert.ok(reports[1].includes('Feature B needs work'));

      fs.unlinkSync(tempFile1);
      fs.unlinkSync(tempFile2);
    });

    test('handles DISSENT tags', () => {
      const mockReport = `# Report
DISSENT: [security-first] — Must implement 2FA vs current password-only approach`;

      const tempFile = path.join(__dirname, 'temp-dissent.md');
      fs.writeFileSync(tempFile, mockReport);

      const reports = parseReports([tempFile]);
      assert.ok(reports[0].includes('DISSENT'));
      assert.ok(reports[0].includes('2FA'));

      fs.unlinkSync(tempFile);
    });

    test('handles QUESTION tags', () => {
      const mockReport = `# Report
QUESTION for Security-Team: Should we use JWT or session tokens?`;

      const tempFile = path.join(__dirname, 'temp-question.md');
      fs.writeFileSync(tempFile, mockReport);

      const reports = parseReports([tempFile]);
      assert.ok(reports[0].includes('QUESTION'));

      fs.unlinkSync(tempFile);
    });
  });

  describe('fetchPRDescription', () => {
    test('handles missing PR number gracefully', async () => {
      const description = await fetchPRDescription(null);
      assert.strictEqual(description, null);
    });

    test('returns null when GITHUB_TOKEN not set', async () => {
      const originalToken = process.env.GITHUB_TOKEN;
      delete process.env.GITHUB_TOKEN;
      
      const description = await fetchPRDescription(42);
      assert.strictEqual(description, null);
      
      if (originalToken) process.env.GITHUB_TOKEN = originalToken;
    });
  });

  describe('enforceWordLimit', () => {
    test('keeps text under limit', () => {
      const text = 'Short text';
      const result = enforceWordLimit(text, 500);
      assert.strictEqual(result, text);
    });

    test('truncates text exceeding limit', () => {
      const words = Array(600).fill('word').join(' ');
      const result = enforceWordLimit(words, 500);
      const wordCount = result.split(/\s+/).length;
      assert.ok(wordCount <= 500);
    });

    test('preserves complete sentences when truncating', () => {
      const text = 'First sentence. ' + Array(500).fill('word').join(' ') + '. Last sentence.';
      const result = enforceWordLimit(text, 100);
      // Should end with period or ellipsis
      assert.ok(/[.…]$/.test(result));
    });

    test('adds ellipsis when truncated', () => {
      const words = Array(600).fill('word').join(' ');
      const result = enforceWordLimit(words, 500);
      assert.ok(result.includes('…'));
    });
  });

  describe('generateBrief', () => {
    test('produces structured brief with all sections', async () => {
      const mockReport = `# Round 1 Report — Claude
## Executive Summary
- Feature X implemented
- 25 tests passing
- No critical issues

## Analysis
### High
- Performance optimization needed`;

      const tempFile = path.join(__dirname, 'temp-full-brief.md');
      fs.writeFileSync(tempFile, mockReport);

      const brief = await generateBrief({
        release: 'R3',
        reports: [tempFile],
        prNumber: null,
        notes: null,
        maxWords: 500
      });

      assert.ok(brief.includes('## Gate Brief — R3'));
      assert.ok(brief.includes('### Summary'));
      assert.ok(brief.includes('### Deliverables'));
      assert.ok(brief.includes('### Quality Metrics'));
      assert.ok(brief.includes('### Risks & Blockers'));
      assert.ok(brief.includes('### Recommendation'));

      fs.unlinkSync(tempFile);
    });

    test('enforces word limit on full brief', async () => {
      const longReport = `# Report\n` + Array(1000).fill('word').join(' ');
      const tempFile = path.join(__dirname, 'temp-long.md');
      fs.writeFileSync(tempFile, longReport);

      const brief = await generateBrief({
        release: 'R3',
        reports: [tempFile],
        maxWords: 500
      });

      const wordCount = brief.split(/\s+/).length;
      assert.ok(wordCount <= 500);

      fs.unlinkSync(tempFile);
    });

    test('extracts test metrics from reports', async () => {
      const mockReport = `# Report
Tests: 42 passing / 45 total
Coverage: 87%`;

      const tempFile = path.join(__dirname, 'temp-metrics.md');
      fs.writeFileSync(tempFile, mockReport);

      const brief = await generateBrief({
        release: 'R3',
        reports: [tempFile],
        maxWords: 500
      });

      assert.ok(brief.includes('42 passing'));
      assert.ok(brief.includes('87%'));

      fs.unlinkSync(tempFile);
    });

    test('extracts recommendation', async () => {
      const mockReport = `# Report
Recommendation: **GO** — All acceptance criteria met`;

      const tempFile = path.join(__dirname, 'temp-recommendation.md');
      fs.writeFileSync(tempFile, mockReport);

      const brief = await generateBrief({
        release: 'R3',
        reports: [tempFile],
        maxWords: 500
      });

      assert.ok(/\*\*GO\*\*|\*\*NO-GO\*\*|\*\*CONDITIONAL\*\*/.test(brief));

      fs.unlinkSync(tempFile);
    });

    test('includes PR description placeholder when provided', async () => {
      const mockReport = `# Report\nBasic content`;
      const tempFile = path.join(__dirname, 'temp-pr.md');
      fs.writeFileSync(tempFile, mockReport);

      // Mock PR fetch will return null without GITHUB_TOKEN
      const brief = await generateBrief({
        release: 'R3',
        reports: [tempFile],
        prNumber: 42,
        maxWords: 500
      });

      assert.ok(brief);
      
      fs.unlinkSync(tempFile);
    });
  });

  describe('Integration', () => {
    test('generates complete brief from multiple sources', async () => {
      const report1 = `# Round 1 Report — Claude
## Executive Summary
- Authentication system complete
- OAuth2 + JWT implementation
- 35 tests passing

## Analysis
### High Priority
- Rate limiting needs configuration

## Considerations
Balance security vs UX

DISSENT: [security-first] — Must add 2FA before launch`;

      const report2 = `# Round 1 Report — ChatGPT
## Executive Summary
- API endpoints implemented
- Documentation complete
- Performance benchmarks good

## Analysis
### Medium Priority
- Cache invalidation strategy needed

QUESTION for DevOps: CDN configuration?`;

      const temp1 = path.join(__dirname, 'temp-int-1.md');
      const temp2 = path.join(__dirname, 'temp-int-2.md');
      
      fs.writeFileSync(temp1, report1);
      fs.writeFileSync(temp2, report2);

      const brief = await generateBrief({
        release: 'R3',
        reports: [temp1, temp2],
        maxWords: 500
      });

      // Verify structure
      assert.ok(brief.includes('## Gate Brief — R3'));
      assert.ok(brief.includes('### Summary'));
      
      // Verify key content extracted
      assert.ok(brief.includes('Authentication') || brief.includes('OAuth2') || brief.includes('35 tests'));
      
      // Verify dissent/questions captured
      assert.ok(brief.includes('2FA') || brief.includes('DISSENT') || brief.includes('QUESTION'));
      
      // Verify word limit
      const wordCount = brief.split(/\s+/).length;
      assert.ok(wordCount <= 500);

      fs.unlinkSync(temp1);
      fs.unlinkSync(temp2);
    });
  });
});
