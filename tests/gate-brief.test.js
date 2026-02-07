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

    test('enforces 500-word limit with extremely long input reports', async () => {
      // BUG-002: Validate word count enforcement with very long input
      // Create very long, realistic reports (each ~2000+ words)
      const longReport1 = `# Round 1 Report — Claude
## Topic: Database Migration

## Executive Summary
- Database migration required, 127 tests passing / 130 total, Coverage: 89%

## Analysis
### Critical
- Foreign key constraints need re-validation
- ${Array(300).fill('Critical consideration with detailed explanation').join(' ')}

### High Priority
- Backup verification process needed
- ${Array(200).fill('High priority technical item').join(' ')}

## Considerations
${Array(300).fill('Trade-off analysis details').join(' ')}

## Recommendation
**GO** — Migration plan is solid`;

      const longReport2 = `# Round 1 Report — ChatGPT
## Topic: Security Audit

## Executive Summary
- 3 high severity vulnerabilities found
- DISSENT: [security-first] — Delay launch until ALL findings resolved

## Analysis
### Critical
- SQL injection vulnerability (CVE-2024-1234)
- ${Array(250).fill('SQL injection details').join(' ')}
- XSS vulnerability in profile
- ${Array(250).fill('XSS analysis').join(' ')}

### High Priority
- ${Array(200).fill('High severity issue details').join(' ')}

## Open Questions
QUESTION for Security-Team: Run another audit after fixes?`;

      const longReport3 = `# Round 1 Report — Gemini
## Topic: Performance Results

## Executive Summary
- 45 tests passing, avg response 250ms

## Analysis
### Critical
- Database N+1 problem
- ${Array(300).fill('Performance profiling data').join(' ')}

### Recommendations
${Array(500).fill('Performance optimization details').join(' ')}

DISSENT: [performance-focused] — Need sub-200ms response times`;

      const temp1 = path.join(__dirname, 'temp-verylong-1.md');
      const temp2 = path.join(__dirname, 'temp-verylong-2.md');
      const temp3 = path.join(__dirname, 'temp-verylong-3.md');
      
      fs.writeFileSync(temp1, longReport1);
      fs.writeFileSync(temp2, longReport2);
      fs.writeFileSync(temp3, longReport3);

      const longNotes = Array(500).fill('Additional context info').join(' ');
      const notesFile = path.join(__dirname, 'temp-longnotes.md');
      fs.writeFileSync(notesFile, longNotes);

      const brief = await generateBrief({
        release: 'R3',
        reports: [temp1, temp2, temp3],
        notes: notesFile,
        maxWords: 500
      });

      // CRITICAL: Verify strict word limit enforcement
      const wordCount = brief.split(/\s+/).filter(w => w.length > 0).length;
      assert.ok(wordCount <= 500, `Word count ${wordCount} exceeds limit of 500`);

      // Verify structure maintained even with truncation
      assert.ok(brief.includes('## Gate Brief'), 'Missing brief header');
      assert.ok(brief.includes('### Summary'), 'Missing summary section');
      
      // Verify critical information is NOT silently lost
      assert.ok(brief.includes('R3'), 'Release name missing');
      assert.ok(/\d{4}-\d{2}-\d{2}/.test(brief), 'Date missing');
      
      // Verify test numbers are not corrupted
      const testMatch = brief.match(/(\d+)\s+(?:tests?\s+)?passing/);
      if (testMatch) {
        const testCount = parseInt(testMatch[1]);
        assert.ok(testCount > 0 && testCount < 1000, 'Test count corrupted');
      }
      
      // Verify no broken markdown
      const headerLines = brief.split('\n').filter(line => line.startsWith('#'));
      headerLines.forEach(header => {
        assert.ok(header.length > 2, 'Truncated header found');
      });
      
      // Verify graceful truncation
      const lastLine = brief.trim().split('\n').pop();
      assert.ok(/[.…!?]$/.test(lastLine) || /\*\*$/.test(lastLine), 'Brief does not end gracefully');

      fs.unlinkSync(temp1);
      fs.unlinkSync(temp2);
      fs.unlinkSync(temp3);
      fs.unlinkSync(notesFile);
    });

    test('preserves critical information with mixed report lengths', async () => {
      // BUG-002: Ensure short critical reports not lost when mixed with long reports
      const shortReport = `# Report — Claude
Tests: 42 passing
DISSENT: [critical-issue] — Must resolve CVE-2024-9999 before launch`;

      const extremelyLongReport = `# Report — ChatGPT
${Array(2000).fill('Analysis paragraph').join(' ')}
127 tests passing / 130 total
${Array(2000).fill('More analysis').join(' ')}`;

      const temp1 = path.join(__dirname, 'temp-mixedshort.md');
      const temp2 = path.join(__dirname, 'temp-mixedlong.md');
      
      fs.writeFileSync(temp1, shortReport);
      fs.writeFileSync(temp2, extremelyLongReport);

      const brief = await generateBrief({
        release: 'R3',
        reports: [temp1, temp2],
        maxWords: 500
      });

      const wordCount = brief.split(/\s+/).filter(w => w.length > 0).length;
      assert.ok(wordCount <= 500, `Word count ${wordCount} exceeds limit`);

      // CRITICAL: Ensure the important DISSENT is not silently lost
      assert.ok(brief.includes('DISSENT') || brief.includes('CVE-2024-9999') || brief.includes('critical'), 
        'Critical dissent silently truncated');
      
      // Ensure test metrics present
      assert.ok(/\d+\s+(?:tests?\s+)?passing/.test(brief), 'Test metrics missing');

      fs.unlinkSync(temp1);
      fs.unlinkSync(temp2);
    });
  });
});
