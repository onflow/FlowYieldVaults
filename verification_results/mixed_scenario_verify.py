#!/usr/bin/env python3
"""
Mixed Scenario Verification Script for Tidal Protocol

This script analyzes mixed scenario test outputs where both auto-borrow
and auto-balancer are tested simultaneously with independent price movements.
"""

import re
import json
import sys
from decimal import Decimal
from datetime import datetime

def parse_mixed_scenario_log(log_file):
    """Parse mixed scenario test output and extract key data"""
    
    results = {
        'scenario_name': None,
        'initial_state': {},
        'stages': [],
        'final_state': {},
        'interactions': [],
        'critical_events': [],
        'price_correlations': [],
        'all_token_data': {
            'FLOW': [],
            'MOET': [],
            'YieldToken': []
        }
    }
    
    current_stage = None
    in_stage = False
    stage_data = {}
    
    # Comprehensive format patterns (handles escaped Unicode)
    mixed_state_pattern = re.compile(r'MIXED SCENARIO STATE: (Initial State|Before Rebalancing|After Rebalancing)')
    
    # Price patterns
    flow_price_pattern = re.compile(r'\*\s*FLOW:\s*([0-9.,]+)\s*MOET')
    yield_price_pattern = re.compile(r'\*\s*YieldToken:\s*([0-9.,]+)\s*MOET')
    moet_price_pattern = re.compile(r'\*\s*MOET:\s*([0-9.,]+)')
    
    # Balance patterns 
    health_ratio_pattern = re.compile(r'\|\s*Health Ratio:\s*([0-9.,]+)')
    moet_debt_pattern = re.compile(r'\|\s*MOET Debt:\s*([0-9.,]+)')
    yield_balance_pattern = re.compile(r'\|\s*YieldToken Balance:\s*([0-9.,]+)')
    
    # Stage patterns
    stage_pattern = re.compile(r'== Stage (\d+):\s*(.+)')
    scenario_pattern = re.compile(r'\|== MIXED SCENARIO:\s*(.+)')
    
    # State tracking
    current_state_type = None  # 'initial', 'before', 'after'
    temp_before_data = {}
    temp_after_data = {}
    
    with open(log_file, 'r') as f:
        lines = f.readlines()
        
    for i, line in enumerate(lines):
        line = line.strip()
        
        # Check for scenario name
        scenario_match = scenario_pattern.search(line)
        if scenario_match:
            results['scenario_name'] = scenario_match.group(1)
            continue
            
        # Check for stage start
        stage_match = stage_pattern.search(line)
        if stage_match:
            # Save any pending stage data
            if current_stage is not None and temp_before_data:
                stage_entry = {
                    'stage_num': current_stage['num'],
                    'description': current_stage['desc'],
                    'flow_price': temp_before_data.get('flow_price'),
                    'yield_price': temp_before_data.get('yield_price'),
                    'health_before': temp_before_data.get('health'),
                    'health_after': temp_after_data.get('health'),
                    'balance_before': temp_before_data.get('yield_balance'),
                    'balance_after': temp_after_data.get('yield_balance'),
                    'health_change': None,
                    'balance_change': None
                }
                
                # Calculate changes
                if stage_entry['health_before'] and stage_entry['health_after']:
                    stage_entry['health_change'] = str(
                        Decimal(stage_entry['health_after']) - Decimal(stage_entry['health_before'])
                    )
                if stage_entry['balance_before'] and stage_entry['balance_after']:
                    stage_entry['balance_change'] = str(
                        Decimal(stage_entry['balance_after']) - Decimal(stage_entry['balance_before'])
                    )
                    
                results['stages'].append(stage_entry)
                
            # Reset for new stage
            current_stage = {
                'num': int(stage_match.group(1)),
                'desc': stage_match.group(2)
            }
            temp_before_data = {}
            temp_after_data = {}
            continue
            
        # Check for state markers
        state_match = mixed_state_pattern.search(line)
        if state_match:
            state_type = state_match.group(1)
            if state_type == "Initial State":
                current_state_type = 'initial'
            elif state_type == "Before Rebalancing":
                current_state_type = 'before'
            elif state_type == "After Rebalancing":
                current_state_type = 'after'
            continue
            
        # Extract data based on current state
        if current_state_type:
            # Extract prices
            flow_match = flow_price_pattern.search(line)
            if flow_match:
                price = flow_match.group(1)
                if current_state_type == 'initial':
                    results['initial_state']['flow_price'] = price
                elif current_state_type == 'before':
                    temp_before_data['flow_price'] = price
                elif current_state_type == 'after':
                    temp_after_data['flow_price'] = price
                    
            yield_match = yield_price_pattern.search(line)
            if yield_match:
                price = yield_match.group(1)
                if current_state_type == 'initial':
                    results['initial_state']['yield_price'] = price
                elif current_state_type == 'before':
                    temp_before_data['yield_price'] = price
                elif current_state_type == 'after':
                    temp_after_data['yield_price'] = price
                    
            moet_match = moet_price_pattern.search(line)
            if moet_match:
                price = moet_match.group(1)
                results['all_token_data']['MOET'].append(price)
                    
            # Extract health ratio
            health_match = health_ratio_pattern.search(line)
            if health_match:
                health = health_match.group(1)
                if current_state_type == 'initial':
                    results['initial_state']['borrow_health'] = health
                elif current_state_type == 'before':
                    temp_before_data['health'] = health
                elif current_state_type == 'after':
                    temp_after_data['health'] = health
                    
            # Extract MOET debt
            debt_match = moet_debt_pattern.search(line)
            if debt_match:
                debt = debt_match.group(1)
                if current_state_type == 'initial':
                    results['initial_state']['moet_debt'] = debt
                elif current_state_type == 'before':
                    temp_before_data['moet_debt'] = debt
                elif current_state_type == 'after':
                    temp_after_data['moet_debt'] = debt
                    
            # Extract YieldToken balance
            yield_bal_match = yield_balance_pattern.search(line)
            if yield_bal_match:
                balance = yield_bal_match.group(1)
                if current_state_type == 'initial':
                    results['initial_state']['balancer_balance'] = balance
                elif current_state_type == 'before':
                    temp_before_data['yield_balance'] = balance
                elif current_state_type == 'after':
                    temp_after_data['yield_balance'] = balance
                    
    # Save final stage if any
    if current_stage is not None and temp_before_data:
        stage_entry = {
            'stage_num': current_stage['num'],
            'description': current_stage['desc'],
            'flow_price': temp_before_data.get('flow_price'),
            'yield_price': temp_before_data.get('yield_price'),
            'health_before': temp_before_data.get('health'),
            'health_after': temp_after_data.get('health'),
            'balance_before': temp_before_data.get('yield_balance'),
            'balance_after': temp_after_data.get('yield_balance'),
            'health_change': None,
            'balance_change': None
        }
        
        # Calculate changes
        if stage_entry['health_before'] and stage_entry['health_after']:
            stage_entry['health_change'] = str(
                Decimal(stage_entry['health_after']) - Decimal(stage_entry['health_before'])
            )
        if stage_entry['balance_before'] and stage_entry['balance_after']:
            stage_entry['balance_change'] = str(
                Decimal(stage_entry['balance_after']) - Decimal(stage_entry['balance_before'])
            )
            
        results['stages'].append(stage_entry)
        
    # Set final state from last stage
    if results['stages']:
        last_stage = results['stages'][-1]
        results['final_state'] = {
            'flow_price': last_stage.get('flow_price'),
            'yield_price': last_stage.get('yield_price'),
            'borrow_health': last_stage.get('health_after'),
            'balancer_balance': last_stage.get('balance_after')
        }
    
    return results

def analyze_interactions(results):
    """Analyze interactions between auto-borrow and auto-balancer"""
    
    interactions = []
    
    for i, stage in enumerate(results['stages']):
        # Check for critical conditions
        health_after = stage.get('health_after')
        balance_after = stage.get('balance_after')
        balance_before = stage.get('balance_before')
        
        if health_after:
            health_val = Decimal(health_after)
            if health_val < Decimal('0.5'):
                if balance_after and Decimal(balance_after) == Decimal('0'):
                    interactions.append({
                        'stage': i,
                        'type': 'critical_both',
                        'description': f"Stage {i}: Both systems in critical state - health {health_after}, balance wiped out",
                        'flow_price': str(stage.get('flow_price', 'N/A')),
                        'yield_price': str(stage.get('yield_price', 'N/A'))
                    })
                else:
                    interactions.append({
                        'stage': i,
                        'type': 'critical_borrow',
                        'description': f"Stage {i}: Auto-borrow critical - health {health_after}",
                        'flow_price': str(stage.get('flow_price', 'N/A'))
                    })
            
        # Check for large balance changes
        if balance_before and balance_after:
            before_val = Decimal(balance_before)
            after_val = Decimal(balance_after)
            if before_val > 0:
                change_pct = abs((after_val - before_val) / before_val * 100)
                if change_pct > 50:
                    interactions.append({
                        'stage': i,
                        'type': 'large_balance_change',
                        'description': f"Stage {i}: Large balance change {change_pct:.2f}%",
                        'yield_price': str(stage.get('yield_price', 'N/A'))
                    })
    
    return interactions

def calculate_correlations(results):
    """Calculate price correlations and their effects"""
    
    correlations = []
    
    for i in range(1, len(results['stages'])):
        prev = results['stages'][i-1]
        curr = results['stages'][i]
        
        prev_flow = prev.get('flow_price')
        curr_flow = curr.get('flow_price')
        prev_yield = prev.get('yield_price')
        curr_yield = curr.get('yield_price')
        
        if prev_flow and curr_flow and prev_yield and curr_yield:
            prev_flow_dec = Decimal(prev_flow)
            curr_flow_dec = Decimal(curr_flow)
            prev_yield_dec = Decimal(prev_yield)
            curr_yield_dec = Decimal(curr_yield)
            
            if prev_flow_dec > 0 and prev_yield_dec > 0:
                flow_change = (curr_flow_dec - prev_flow_dec) / prev_flow_dec
                yield_change = (curr_yield_dec - prev_yield_dec) / prev_yield_dec
                
                # Determine correlation type
                corr_type = 'neutral'
                if abs(flow_change) < Decimal('0.05') and abs(yield_change) > Decimal('0.2'):
                    corr_type = 'flow_stable_yield_volatile'
                elif abs(yield_change) < Decimal('0.05') and abs(flow_change) > Decimal('0.2'):
                    corr_type = 'yield_stable_flow_volatile'
                elif flow_change * yield_change < 0 and abs(flow_change) > Decimal('0.1') and abs(yield_change) > Decimal('0.1'):
                    corr_type = 'inverse'
                elif flow_change * yield_change > 0 and abs(flow_change) > Decimal('0.1') and abs(yield_change) > Decimal('0.1'):
                    corr_type = 'positive'
                
                correlations.append({
                    'stage': i,
                    'flow_change_pct': float(flow_change * 100),
                    'yield_change_pct': float(yield_change * 100),
                    'correlation_type': corr_type,
                    'health_impact': float(curr.get('health_change') or 0),
                    'balance_impact': float(curr.get('balance_change') or 0)
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
    initial_health = results['initial_state'].get('borrow_health', 'N/A')
    final_health = results['final_state'].get('borrow_health', 'N/A')
    initial_balance = results['initial_state'].get('balancer_balance', 'N/A')
    final_balance = results['final_state'].get('balancer_balance', 'N/A')
    
    print(f"Auto-Borrow Health: {initial_health} → {final_health}")
    print(f"Auto-Balancer Balance: {initial_balance} → {final_balance}")
    
    # Price movements
    print("\n### Price Movements ###")
    for stage in results['stages']:
        if stage['flow_price'] or stage['yield_price']:
            print(f"Stage {stage['stage_num']}: {stage['description']}")
            if stage['flow_price']:
                print(f"  FLOW: {stage['flow_price']} MOET")
            if stage['yield_price']:
                print(f"  YieldToken: {stage['yield_price']} MOET")
            print(f"  Health: {stage.get('health_before', 'N/A')} → {stage.get('health_after', 'N/A')}")
            print(f"  Balance: {stage.get('balance_before', 'N/A')} → {stage.get('balance_after', 'N/A')}")
    
    # Critical events
    if results.get('critical_events'):
        print("\n### Critical Events ###")
        for event in results['critical_events']:
            print(f"- {event['description']}")
    
    # Correlations
    if results.get('correlations'):
        print("\n### Price Correlations ###")
        correlation_types = {}
        for corr in results['correlations']:
            corr_type = corr['correlation_type']
            correlation_types[corr_type] = correlation_types.get(corr_type, 0) + 1
        
        for corr_type, count in correlation_types.items():
            print(f"- {corr_type}: {count} occurrences")
    
    print("\n" + "=" * 80)

def save_results(results, output_file):
    """Save analysis results to JSON"""
    
    summary = {
        'total_stages': len(results['stages']),
        'critical_events': len(results.get('critical_events', [])),
        'final_health_status': 'healthy' if results['final_state'].get('borrow_health') and Decimal(results['final_state']['borrow_health']) > Decimal('1.0') else 'unhealthy',
        'balancer_status': 'active' if results['final_state'].get('balancer_balance') and Decimal(results['final_state']['balancer_balance']) > 0 else 'empty',
        'tokens_tracked': {
            'FLOW': len([s for s in results['stages'] if s.get('flow_price')]),
            'YieldToken': len([s for s in results['stages'] if s.get('yield_price')]),
            'MOET': len(results['all_token_data'].get('MOET', []))
        }
    }
    
    results['summary'] = summary
    
    with open(output_file, 'w') as f:
        json.dump(results, f, indent=2)
    
    print(f"\nResults saved to: {output_file}")

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 mixed_scenario_verify.py <log_file>")
        sys.exit(1)
    
    log_file = sys.argv[1]
    
    print(f"Analyzing mixed scenario log: {log_file}")
    
    # Parse log
    results = parse_mixed_scenario_log(log_file)
    
    # Analyze interactions
    results['interactions'] = analyze_interactions(results)
    
    # Calculate correlations
    results['correlations'] = calculate_correlations(results)
    
    # Generate report
    generate_report(results)
    
    # Save results
    save_results(results, 'mixed_scenario_analysis.json')

if __name__ == "__main__":
    main() 