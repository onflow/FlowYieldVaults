#!/usr/bin/env python3
"""
Mixed Scenario Verification Script
Analyzes test results from mixed price scenarios where FLOW and YieldToken move independently
"""

import re
import sys
import json
from decimal import Decimal, getcontext
from collections import defaultdict

# Set precision for financial calculations
getcontext().prec = 28

def strip_ansi_codes(text):
    """Remove ANSI color codes from text"""
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    return ansi_escape.sub('', text)

def parse_mixed_scenario_log(log_file):
    """Parse mixed scenario test output and extract key data"""
    
    results = {
        'scenario_name': None,
        'initial_state': {},
        'stages': [],
        'final_state': {},
        'interactions': [],
        'critical_events': [],
        'price_correlations': []
    }
    
    current_stage = None
    in_stage = False
    stage_data = {}
    
    with open(log_file, 'r') as f:
        for line in f:
            line = strip_ansi_codes(line.strip())
            
            # Extract content from LOG: "..." format
            if 'LOG: "' in line:
                try:
                    line = line.split('LOG: "')[1].rstrip('"')
                except IndexError:
                    continue
            
            # Extract scenario name
            if "MIXED SCENARIO:" in line:
                results['scenario_name'] = line.split("MIXED SCENARIO:")[1].strip()
            
            # Parse initial state
            elif "Initial State" in line:
                current_stage = "initial"
            elif current_stage == "initial" and "Auto-Borrow Position Health:" in line:
                results['initial_state']['borrow_health'] = Decimal(line.split(":")[1].strip())
            elif current_stage == "initial" and "Auto-Balancer YieldToken Balance:" in line:
                results['initial_state']['balancer_balance'] = Decimal(line.split(":")[1].strip())
                current_stage = None
            
            # Parse stage data
            elif re.match(r"== Stage \d+:", line):
                if stage_data:
                    results['stages'].append(stage_data)
                stage_match = re.search(r"Stage (\d+):", line)
                stage_data = {
                    'stage_num': int(stage_match.group(1)) if stage_match else 0,
                    'description': line.split(":", 1)[1].strip(),
                    'flow_price': None,
                    'yield_price': None,
                    'health_before': None,
                    'health_after': None,
                    'balance_before': None,
                    'balance_after': None,
                    'health_change': None,
                    'balance_change': None
                }
                in_stage = True
            
            # Extract prices
            elif in_stage and "[PRICE UPDATE] Setting FLOW price" in line:
                current_stage = "flow_price"
            elif current_stage == "flow_price" and "New Price:" in line:
                price_match = re.search(r"New Price: ([\d.]+)", line)
                if price_match:
                    stage_data['flow_price'] = Decimal(price_match.group(1))
                current_stage = None
            elif in_stage and "[PRICE UPDATE] Setting YieldToken price" in line:
                current_stage = "yield_price"
            elif current_stage == "yield_price" and "New Price:" in line:
                price_match = re.search(r"New Price: ([\d.]+)", line)
                if price_match:
                    stage_data['yield_price'] = Decimal(price_match.group(1))
                current_stage = None
            
            # Before rebalancing
            elif in_stage and "BEFORE REBALANCING:" in line:
                current_stage = "before"
            elif current_stage == "before" and "Auto-Borrow Health:" in line:
                stage_data['health_before'] = Decimal(line.split(":")[1].strip())
            elif current_stage == "before" and "Auto-Balancer Balance:" in line:
                balance_str = line.split(":")[1].strip().split()[0]
                stage_data['balance_before'] = Decimal(balance_str)
            
            # After rebalancing
            elif in_stage and "AFTER REBALANCING:" in line:
                current_stage = "after"
            elif current_stage == "after" and "Auto-Borrow Health:" in line:
                stage_data['health_after'] = Decimal(line.split(":")[1].strip())
            elif current_stage == "after" and "Auto-Balancer Balance:" in line:
                balance_str = line.split(":")[1].strip().split()[0]
                stage_data['balance_after'] = Decimal(balance_str)
            
            # Changes
            elif in_stage and "Health" in line and ("IMPROVED" in line or "DETERIORATED" in line or "UNCHANGED" in line):
                if "IMPROVED" in line:
                    change = Decimal(line.split("by:")[1].strip())
                    stage_data['health_change'] = change
                elif "DETERIORATED" in line:
                    change = Decimal(line.split("by:")[1].strip())
                    stage_data['health_change'] = -change
                else:
                    stage_data['health_change'] = Decimal('0')
            
            elif in_stage and "Balance" in line and ("INCREASED" in line or "DECREASED" in line or "UNCHANGED" in line):
                if "INCREASED" in line:
                    change = Decimal(line.split("by:")[1].strip())
                    stage_data['balance_change'] = change
                elif "DECREASED" in line:
                    change = Decimal(line.split("by:")[1].strip())
                    stage_data['balance_change'] = -change
                else:
                    stage_data['balance_change'] = Decimal('0')
                current_stage = None
            
            # Final state
            elif "Final State Summary" in line:
                in_stage = False
                if stage_data:
                    results['stages'].append(stage_data)
                    stage_data = {}
            elif "Auto-Borrow Final Health:" in line:
                results['final_state']['borrow_health'] = Decimal(line.split(":")[1].strip())
            elif "Auto-Balancer Final Balance:" in line:
                results['final_state']['balancer_balance'] = Decimal(line.split(":")[1].strip())
    
    return results

def analyze_interactions(results):
    """Analyze interactions between auto-borrow and auto-balancer"""
    
    interactions = []
    
    for i, stage in enumerate(results['stages']):
        # Check for critical conditions
        if stage['health_after'] and stage['health_after'] < Decimal('0.5'):
            if stage['balance_after'] == Decimal('0'):
                interactions.append({
                    'stage': i,
                    'type': 'critical_both',
                    'description': f"Stage {i}: Both systems in critical state - health {stage['health_after']}, balance wiped out",
                    'flow_price': str(stage['flow_price']) if stage['flow_price'] else 'N/A',
                    'yield_price': str(stage['yield_price']) if stage['yield_price'] else 'N/A'
                })
        
        # Check for inverse effects
        if stage['health_change'] and stage['balance_change']:
            if (stage['health_change'] > 0 and stage['balance_change'] < 0) or \
               (stage['health_change'] < 0 and stage['balance_change'] > 0):
                                 interactions.append({
                     'stage': i,
                     'type': 'inverse_effect',
                     'description': f"Stage {i}: Inverse effects - health {'improved' if stage['health_change'] > 0 else 'deteriorated'}, balance {'decreased' if stage['balance_change'] < 0 else 'increased'}",
                     'flow_price': str(stage['flow_price']) if stage['flow_price'] else 'N/A',
                     'yield_price': str(stage['yield_price']) if stage['yield_price'] else 'N/A'
                 })
        
        # Check for wipeout events
        if stage['balance_before'] and stage['balance_before'] > 0 and stage['balance_after'] == 0:
                            interactions.append({
                    'stage': i,
                    'type': 'balancer_wipeout',
                    'description': f"Stage {i}: Auto-balancer wiped out from {stage['balance_before']} to 0",
                    'flow_price': str(stage['flow_price']) if stage['flow_price'] else 'N/A',
                    'yield_price': str(stage['yield_price']) if stage['yield_price'] else 'N/A'
                })
    
    return interactions

def calculate_correlations(results):
    """Calculate price correlations and their effects"""
    
    correlations = []
    
    for i in range(1, len(results['stages'])):
        prev = results['stages'][i-1]
        curr = results['stages'][i]
        
        if prev['flow_price'] and curr['flow_price'] and prev['yield_price'] and curr['yield_price']:
            flow_change = (curr['flow_price'] - prev['flow_price']) / prev['flow_price']
            yield_change = (curr['yield_price'] - prev['yield_price']) / prev['yield_price']
            
            # Determine correlation type
            if abs(flow_change) < Decimal('0.05') and abs(yield_change) > Decimal('0.2'):
                corr_type = 'flow_stable_yield_volatile'
            elif abs(yield_change) < Decimal('0.05') and abs(flow_change) > Decimal('0.2'):
                corr_type = 'yield_stable_flow_volatile'
            elif flow_change * yield_change < 0:
                corr_type = 'inverse'
            elif flow_change * yield_change > 0:
                corr_type = 'positive'
            else:
                corr_type = 'neutral'
            
            correlations.append({
                'stage': i,
                'flow_change_pct': float(flow_change * 100),
                'yield_change_pct': float(yield_change * 100),
                'correlation_type': corr_type,
                'health_impact': float(curr['health_change']) if curr['health_change'] else 0,
                'balance_impact': float(curr['balance_change']) if curr['balance_change'] else 0
            })
    
    return correlations

def generate_report(results):
    """Generate comprehensive report of mixed scenario analysis"""
    
    print("=" * 80)
    print("MIXED SCENARIO VERIFICATION REPORT")
    print("=" * 80)
    print(f"\nScenario: {results['scenario_name']}")
    print(f"Total Stages: {len(results['stages'])}")
    
    # Initial vs Final
    print("\n### Initial vs Final State ###")
    print(f"Auto-Borrow Health: {results['initial_state']['borrow_health']} → {results['final_state']['borrow_health']}")
    print(f"Auto-Balancer Balance: {results['initial_state']['balancer_balance']} → {results['final_state']['balancer_balance']}")
    
    # Key Metrics
    print("\n### Key Metrics ###")
    health_changes = [s['health_change'] for s in results['stages'] if s['health_change']]
    balance_changes = [s['balance_change'] for s in results['stages'] if s['balance_change']]
    
    if health_changes:
        print(f"Average Health Change: {sum(health_changes)/len(health_changes):.8f}")
        print(f"Max Health Improvement: {max(health_changes):.8f}")
        print(f"Max Health Deterioration: {min(health_changes):.8f}")
    
    if balance_changes:
        print(f"Average Balance Change: {sum(balance_changes)/len(balance_changes):.8f}")
        print(f"Max Balance Increase: {max(balance_changes):.8f}")
        print(f"Max Balance Decrease: {min(balance_changes):.8f}")
    
    # Interactions
    interactions = analyze_interactions(results)
    if interactions:
        print("\n### Critical Interactions ###")
        for interaction in interactions:
            print(f"- {interaction['description']}")
            print(f"  FLOW: {interaction['flow_price']}, Yield: {interaction['yield_price']}")
    
    # Correlations
    correlations = calculate_correlations(results)
    if correlations:
        print("\n### Price Correlation Analysis ###")
        corr_types = defaultdict(int)
        for corr in correlations:
            corr_types[corr['correlation_type']] += 1
        
        for corr_type, count in corr_types.items():
            print(f"- {corr_type}: {count} occurrences")
    
    # Critical Events
    print("\n### Critical Events ###")
    critical_count = 0
    for i, stage in enumerate(results['stages']):
        if stage['health_after'] and stage['health_after'] < Decimal('0.5'):
            print(f"- Stage {i}: Critical health level {stage['health_after']}")
            critical_count += 1
        if stage['balance_after'] == Decimal('0') and stage['balance_before'] and stage['balance_before'] > 0:
            print(f"- Stage {i}: Auto-balancer wiped out")
            critical_count += 1
    
    if critical_count == 0:
        print("- No critical events detected")
    
    # Save detailed results
    output_data = {
        'scenario_name': results['scenario_name'],
        'initial_state': {k: str(v) for k, v in results['initial_state'].items()},
        'final_state': {k: str(v) for k, v in results['final_state'].items()},
        'stages': [{k: str(v) if isinstance(v, Decimal) else v for k, v in stage.items()} 
                   for stage in results['stages']],
        'interactions': interactions,
        'correlations': correlations,
        'summary': {
            'total_stages': len(results['stages']),
            'critical_events': critical_count,
            'final_health_status': 'healthy' if results['final_state']['borrow_health'] >= Decimal('1.1') else 'unhealthy',
            'balancer_status': 'active' if results['final_state']['balancer_balance'] > 0 else 'wiped_out'
        }
    }
    
    with open('mixed_scenario_analysis.json', 'w') as f:
        json.dump(output_data, f, indent=2)
    
    print("\nDetailed results saved to mixed_scenario_analysis.json")

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 mixed_scenario_verify.py <log_file>")
        sys.exit(1)
    
    log_file = sys.argv[1]
    results = parse_mixed_scenario_log(log_file)
    generate_report(results)

if __name__ == "__main__":
    main() 