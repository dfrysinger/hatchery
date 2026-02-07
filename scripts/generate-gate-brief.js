#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const { Octokit } = require('@octokit/rest');
const { glob } = require('glob');

/**
 * Parse report files and extract content
 * @param {string[]} filePaths - Array of file paths to parse
 * @returns {string[]} Array of report contents
 */
function parseReports(filePaths) {
  return filePaths.map(filePath => {
    try {
      return fs.readFileSync(filePath, 'utf-8');
    } catch (error) {
      console.error(`Error reading ${filePath}:`, error.message);
      return '';
    }
  }).filter(content => content.length > 0);
}

/**
 * Fetch PR description from GitHub
 * @param {number|null} prNumber - PR number
 * @returns {Promise<string|null>} PR description or null
 */
async function fetchPRDescription(prNumber) {
  if (!prNumber) return null;

  try {
    const token = process.env.GITHUB_TOKEN;
    if (!token) {
      console.warn('GITHUB_TOKEN not set, skipping PR fetch');
      return null;
    }

    const octokit = new Octokit({ auth: token });
    
    // Parse repo from git remote (simplified - assumes origin)
    let owner = 'openclaw';
    let repo = 'hatchery';
    
    try {
      const gitConfig = fs.readFileSync('.git/config', 'utf-8');
      const remoteMatch = gitConfig.match(/github\.com[:/](.+?)\/(.+?)\.git/);
      if (remoteMatch) {
        owner = remoteMatch[1];
        repo = remoteMatch[2];
      }
    } catch (e) {
      // Use defaults
    }

    const { data } = await octokit.pulls.get({
      owner,
      repo,
      pull_number: prNumber
    });

    return data.body || '';
  } catch (error) {
    console.error(`Error fetching PR #${prNumber}:`, error.message);
    return null;
  }
}

/**
 * Enforce word limit on text
 * @param {string} text - Input text
 * @param {number} maxWords - Maximum word count
 * @returns {string} Truncated text
 */
function enforceWordLimit(text, maxWords) {
  const words = text.split(/\s+/);
  
  if (words.length <= maxWords) {
    return text;
  }

  // Truncate to maxWords
  let truncated = words.slice(0, maxWords).join(' ');
  
  // Try to end at a sentence boundary
  const lastPeriod = truncated.lastIndexOf('.');
  if (lastPeriod > truncated.length * 0.8) {
    truncated = truncated.substring(0, lastPeriod + 1);
  } else {
    // Add ellipsis
    truncated += '…';
  }

  return truncated;
}

/**
 * Extract key information from reports
 * @param {string[]} reports - Array of report contents
 * @returns {Object} Extracted information
 */
function extractKeyInfo(reports) {
  const info = {
    features: [],
    tests: { passing: 0, total: 0 },
    coverage: null,
    vulnerabilities: { high: 0, medium: 0 },
    risks: [],
    dissent: [],
    questions: [],
    recommendations: []
  };

  const combinedText = reports.join('\n\n');

  // Extract test metrics
  const testMatch = combinedText.match(/(\d+)\s+(?:tests?\s+)?passing(?:\s*\/\s*(\d+)\s+total)?/i);
  if (testMatch) {
    info.tests.passing = parseInt(testMatch[1]);
    info.tests.total = testMatch[2] ? parseInt(testMatch[2]) : info.tests.passing;
  }

  // Extract coverage
  const coverageMatch = combinedText.match(/coverage:?\s*(\d+)%/i);
  if (coverageMatch) {
    info.coverage = parseInt(coverageMatch[1]);
  }

  // Extract vulnerabilities
  const vulnHighMatch = combinedText.match(/(\d+)\s+high(?:\s+vulnerabilit(?:y|ies))?/i);
  const vulnMedMatch = combinedText.match(/(\d+)\s+medium(?:\s+vulnerabilit(?:y|ies))?/i);
  if (vulnHighMatch) info.vulnerabilities.high = parseInt(vulnHighMatch[1]);
  if (vulnMedMatch) info.vulnerabilities.medium = parseInt(vulnMedMatch[1]);

  // Extract DISSENT
  const dissentMatches = combinedText.match(/DISSENT:.*$/gm);
  if (dissentMatches) {
    info.dissent = dissentMatches;
  }

  // Extract QUESTION
  const questionMatches = combinedText.match(/QUESTION.*$/gm);
  if (questionMatches) {
    info.questions = questionMatches;
  }

  // Extract recommendations
  const recMatch = combinedText.match(/recommendation:?\s*\*\*(GO|NO-GO|CONDITIONAL)\*\*/i);
  if (recMatch) {
    info.recommendations.push(recMatch[0]);
  }

  // Extract features/tasks (simplified)
  const taskMatches = combinedText.match(/TASK-\d+:?\s+[^\n]+/g);
  if (taskMatches) {
    info.features = taskMatches.slice(0, 5); // Limit to 5
  }

  // Extract risks from High Priority sections
  const highPrioritySection = combinedText.match(/###\s+(?:High|Critical)[^\#]*/gi);
  if (highPrioritySection) {
    const riskLines = highPrioritySection[0].match(/^[-•*]\s+.+$/gm);
    if (riskLines) {
      info.risks = riskLines.slice(0, 5);
    }
  }

  return info;
}

/**
 * Generate gate brief
 * @param {Object} options - Generation options
 * @returns {Promise<string>} Generated brief
 */
async function generateBrief(options) {
  const { release, reports: reportPaths, prNumber, notes, maxWords = 500 } = options;

  // Parse reports
  const reports = parseReports(reportPaths);
  
  // Fetch PR description if requested
  let prDescription = null;
  if (prNumber) {
    prDescription = await fetchPRDescription(prNumber);
  }

  // Read notes if provided
  let notesContent = null;
  if (notes && fs.existsSync(notes)) {
    notesContent = fs.readFileSync(notes, 'utf-8');
  }

  // Extract key information
  const info = extractKeyInfo(reports);

  // Build brief
  const today = new Date().toISOString().split('T')[0];
  
  let brief = `## Gate Brief — ${release}\n`;
  brief += `**Date:** ${today}\n`;
  brief += `**Prepared by:** Judge\n\n`;

  // Summary
  brief += `### Summary\n`;
  const summaryParts = [];
  if (info.features.length > 0) {
    summaryParts.push(`${info.features.length} deliverable(s) reviewed`);
  }
  if (info.tests.passing > 0) {
    summaryParts.push(`${info.tests.passing} tests passing`);
  }
  if (info.risks.length > 0) {
    summaryParts.push(`${info.risks.length} risk(s) identified`);
  }
  brief += summaryParts.join(', ') + '.\n\n';

  // Deliverables
  brief += `### Deliverables\n`;
  if (info.features.length > 0) {
    info.features.forEach(feature => {
      brief += `- ${feature}\n`;
    });
  } else {
    brief += '- (No specific tasks identified)\n';
  }
  brief += '\n';

  // Quality Metrics
  brief += `### Quality Metrics\n`;
  if (info.tests.passing > 0) {
    brief += `- Tests: ${info.tests.passing} passing`;
    if (info.tests.total > 0) {
      brief += ` / ${info.tests.total} total`;
    }
    brief += '\n';
  }
  if (info.coverage !== null) {
    brief += `- Coverage: ${info.coverage}%\n`;
  }
  if (info.vulnerabilities.high > 0 || info.vulnerabilities.medium > 0) {
    brief += `- Vulnerabilities: ${info.vulnerabilities.high} high, ${info.vulnerabilities.medium} medium\n`;
  }
  if (info.tests.passing === 0 && info.coverage === null) {
    brief += '- (No metrics available)\n';
  }
  brief += '\n';

  // Risks & Blockers
  brief += `### Risks & Blockers\n`;
  if (info.risks.length > 0) {
    info.risks.forEach(risk => {
      brief += `${risk}\n`;
    });
  }
  if (info.dissent.length > 0) {
    brief += '\n**Dissenting opinions:**\n';
    info.dissent.forEach(d => {
      brief += `- ${d}\n`;
    });
  }
  if (info.questions.length > 0) {
    brief += '\n**Open questions:**\n';
    info.questions.forEach(q => {
      brief += `- ${q}\n`;
    });
  }
  if (info.risks.length === 0 && info.dissent.length === 0 && info.questions.length === 0) {
    brief += '- None identified\n';
  }
  brief += '\n';

  // Recommendation
  brief += `### Recommendation\n`;
  if (info.recommendations.length > 0) {
    brief += info.recommendations[0] + '\n';
  } else {
    // Default based on metrics
    if (info.vulnerabilities.high > 0) {
      brief += '**NO-GO** — High severity vulnerabilities must be resolved.\n';
    } else if (info.tests.passing > 0 && info.coverage && info.coverage >= 80) {
      brief += '**GO** — Metrics meet quality standards.\n';
    } else {
      brief += '**CONDITIONAL** — Review required for quality metrics.\n';
    }
  }

  // Append PR description if available
  if (prDescription) {
    brief += `\n**PR #${prNumber}:**\n${prDescription.substring(0, 200)}...\n`;
  }

  // Append notes if available
  if (notesContent) {
    brief += `\n**Additional notes:**\n${notesContent.substring(0, 200)}...\n`;
  }

  // Enforce word limit
  return enforceWordLimit(brief, maxWords);
}

// CLI interface
if (require.main === module) {
  const yargs = require('yargs/yargs');
  const { hideBin } = require('yargs/helpers');

  const argv = yargs(hideBin(process.argv))
    .option('release', {
      alias: 'r',
      description: 'Release name',
      type: 'string',
      demandOption: true
    })
    .option('reports', {
      description: 'Report file glob pattern',
      type: 'string',
      demandOption: true
    })
    .option('pr', {
      description: 'Pull request number',
      type: 'number'
    })
    .option('notes', {
      description: 'Additional notes file',
      type: 'string'
    })
    .option('output', {
      alias: 'o',
      description: 'Output file (default: stdout)',
      type: 'string'
    })
    .option('max-words', {
      description: 'Maximum word count',
      type: 'number',
      default: 500
    })
    .help()
    .argv;

  (async () => {
    try {
      // Resolve glob pattern
      const reportFiles = await glob(argv.reports);
      
      if (reportFiles.length === 0) {
        console.error(`No reports found matching: ${argv.reports}`);
        process.exit(1);
      }

      const brief = await generateBrief({
        release: argv.release,
        reports: reportFiles,
        prNumber: argv.pr,
        notes: argv.notes,
        maxWords: argv['max-words']
      });

      if (argv.output) {
        fs.writeFileSync(argv.output, brief);
        console.log(`Brief written to: ${argv.output}`);
      } else {
        console.log(brief);
      }
    } catch (error) {
      console.error('Error generating brief:', error.message);
      process.exit(1);
    }
  })();
}

// Export for testing
module.exports = {
  generateBrief,
  parseReports,
  fetchPRDescription,
  enforceWordLimit,
  extractKeyInfo
};
