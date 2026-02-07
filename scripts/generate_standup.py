#!/usr/bin/env python3
"""
generate-standup.py -- Generate daily standup reports from sprint-state.json

Usage:
    ./generate-standup.py [--date YYYY-MM-DD] [--format md|json|slack] [--output FILE]
    
Examples:
    ./generate-standup.py
    ./generate-standup.py --date 2026-02-08
    ./generate-standup.py --format json --output standup.json
"""
import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Any


DEFAULT_STATE_FILE = os.environ.get(
    'SPRINT_STATE_FILE',
    str(Path.home() / 'clawd' / 'shared' / 'sprint-state.json')
)


def load_sprint_state(filepath: str) -> Dict[str, Any]:
    """
    Load and validate sprint-state.json
    
    Args:
        filepath: Path to sprint-state.json
        
    Returns:
        Parsed JSON dict
        
    Raises:
        FileNotFoundError: If file doesn't exist
        ValueError: If JSON is invalid
    """
    if not os.path.exists(filepath):
        raise FileNotFoundError(f"sprint-state.json not found at: {filepath}")
    
    try:
        with open(filepath, 'r', encoding='utf-8') as f:
            return json.load(f)
    except json.JSONDecodeError as e:
        raise ValueError(f"Invalid JSON in {filepath}: {e}")


def parse_sprint_state(state: Dict[str, Any]) -> Dict[str, Any]:
    """
    Parse sprint state and categorize tasks
    
    Args:
        state: Sprint state dict from JSON
        
    Returns:
        Parsed data dict with categorized tasks
        
    Raises:
        ValueError: If required fields are missing
    """
    if 'sprint' not in state:
        raise ValueError("Missing required field: sprint")
    if 'tasks' not in state:
        raise ValueError("Missing required field: tasks")
    
    sprint = state['sprint']
    tasks = state['tasks']
    
    # Categorize tasks by status
    completed = []
    in_progress = []
    blocked = []
    up_next = []
    
    for task in tasks:
        status = task.get('status', '').lower()
        
        if status in ['done', 'completed', 'merged']:
            completed.append(task)
        elif status in ['in-progress', 'in_progress', 'assigned']:
            in_progress.append(task)
        elif status == 'blocked':
            blocked.append(task)
        elif status in ['not-started', 'not_started', 'pending']:
            up_next.append(task)
    
    return {
        'release': sprint.get('release', 'Unknown'),
        'release_name': sprint.get('name', ''),
        'completed': completed,
        'in_progress': in_progress,
        'blocked': blocked,
        'up_next': up_next,
        'sprint_notes': []  # Could be extracted from state.metadata or sprint.notes
    }


def format_task(task: Dict[str, Any], show_details: bool = True) -> str:
    """
    Format a single task line
    
    Args:
        task: Task dict
        show_details: Whether to include status notes/blockers
        
    Returns:
        Formatted task string
    """
    task_id = task.get('id', 'UNKNOWN')
    title = task.get('title', 'No title')
    assignee = task.get('assignee', '')
    
    # Truncate long titles
    max_title_len = 50
    if len(title) > max_title_len:
        title = title[:max_title_len-3] + "..."
    
    line = f"- {task_id}: {title}"
    
    if assignee:
        line += f" ({assignee})"
    
    if show_details:
        # Add notes or blockers
        notes = task.get('notes', [])
        blockers = task.get('blockers', [])
        
        if notes and len(notes) > 0:
            line += f" — {notes[0]}"
        elif blockers and len(blockers) > 0:
            line += f" — {blockers[0]}"
    
    return line


def format_standup(data: Dict[str, Any], date: str = None) -> str:
    """
    Format standup report in markdown
    
    Args:
        data: Parsed sprint data
        date: Date string (YYYY-MM-DD), defaults to today
        
    Returns:
        Formatted markdown string
    """
    if date is None:
        date = datetime.utcnow().strftime('%Y-%m-%d')
    
    release = data['release']
    release_name = data['release_name']
    completed = data['completed']
    in_progress = data['in_progress']
    blocked = data['blocked']
    up_next = data['up_next']
    sprint_notes = data.get('sprint_notes', [])
    
    # Build report
    lines = [
        f"## Daily Standup — {date}",
        f"**Release:** {release} — {release_name}",
        "",
    ]
    
    # Completed
    lines.append("### ✅ Completed Yesterday")
    if completed:
        for task in completed[:5]:  # Limit to 5 to control length
            lines.append(format_task(task, show_details=False))
    else:
        lines.append("- None")
    lines.append("")
    
    # In Progress
    lines.append("### 🏗️ In Progress")
    if in_progress:
        for task in in_progress[:5]:  # Limit to 5
            lines.append(format_task(task, show_details=True))
    else:
        lines.append("- None")
    lines.append("")
    
    # Blocked
    lines.append("### ⏸️ Blocked")
    if blocked:
        for task in blocked[:3]:  # Limit to 3
            lines.append(format_task(task, show_details=True))
    else:
        lines.append("- None")
    lines.append("")
    
    # Up Next
    lines.append("### 📋 Up Next")
    if up_next:
        for task in up_next[:3]:  # Limit to 3
            lines.append(format_task(task, show_details=False))
    else:
        lines.append("- None")
    lines.append("")
    
    # Notes
    if sprint_notes:
        lines.append("### Notes")
        for note in sprint_notes[:2]:  # Limit to 2
            lines.append(f"- {note}")
        lines.append("")
    
    output = "\n".join(lines)
    
    # Enforce length limit (1000 chars for Discord)
    if len(output) > 1000:
        # Truncate and add indicator
        output = output[:997] + "..."
    
    return output


def format_json(data: Dict[str, Any], date: str = None) -> str:
    """Format standup report as JSON"""
    if date is None:
        date = datetime.utcnow().strftime('%Y-%m-%d')
    
    return json.dumps({
        'date': date,
        'release': f"{data['release']} — {data['release_name']}",
        'summary': {
            'completed': len(data['completed']),
            'in_progress': len(data['in_progress']),
            'blocked': len(data['blocked']),
            'up_next': len(data['up_next'])
        },
        'tasks': {
            'completed': data['completed'],
            'in_progress': data['in_progress'],
            'blocked': data['blocked'],
            'up_next': data['up_next']
        }
    }, indent=2)


def format_slack(data: Dict[str, Any], date: str = None) -> str:
    """Format standup report for Slack (mrkdwn)"""
    # Slack uses mrkdwn, similar to markdown but with slight differences
    # For now, use same format as markdown
    return format_standup(data, date)


def parse_args(args=None):
    """Parse command-line arguments"""
    parser = argparse.ArgumentParser(
        description='Generate daily standup reports from sprint-state.json'
    )
    parser.add_argument(
        '--date',
        default=datetime.utcnow().strftime('%Y-%m-%d'),
        help='Date for report (YYYY-MM-DD), default: today'
    )
    parser.add_argument(
        '--format',
        choices=['md', 'json', 'slack'],
        default='md',
        help='Output format (default: md)'
    )
    parser.add_argument(
        '--output',
        help='Output file (default: stdout)'
    )
    parser.add_argument(
        '--state-file',
        default=DEFAULT_STATE_FILE,
        help=f'Path to sprint-state.json (default: {DEFAULT_STATE_FILE})'
    )
    
    return parser.parse_args(args)


def main():
    """Main entry point"""
    args = parse_args()
    
    try:
        # Load and parse
        state = load_sprint_state(args.state_file)
        data = parse_sprint_state(state)
        
        # Format
        if args.format == 'json':
            output = format_json(data, args.date)
        elif args.format == 'slack':
            output = format_slack(data, args.date)
        else:  # md
            output = format_standup(data, args.date)
        
        # Write output
        if args.output:
            with open(args.output, 'w', encoding='utf-8') as f:
                f.write(output)
            print(f"Standup report written to: {args.output}", file=sys.stderr)
        else:
            print(output)
        
        return 0
        
    except (FileNotFoundError, ValueError) as e:
        print(f"Error: {e}", file=sys.stderr)
        return 1
    except Exception as e:
        print(f"Unexpected error: {e}", file=sys.stderr)
        return 2


if __name__ == '__main__':
    sys.exit(main())
