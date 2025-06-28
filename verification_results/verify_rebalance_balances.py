#!/usr/bin/env python3
"""
Rebalance Balance Verification for Tidal Protocol

This script parses Cadence test logs produced by the comprehensive test
suite and verifies that the MOET debt after every auto-borrow position
rebalance matches the mathematically expected value within a given
tolerance.

Expected debt formula (auto-borrow only):
    effectiveCollateral = depositedFLOW * FLOW_price * collateralFactor
    expectedDebt       = effectiveCollateral / targetHealth

Protocol constants assumed (can be overridden via CLI):
    collateralFactor = 0.8
    targetHealth     = 1.3
    tolerance        = 0.0001   # 0.01 %

The script scans for the following markers in the log file:
  - "Creating position with <amount> FLOW"           → deposit amount
  - "[PRICE UPDATE]" block with FlowToken identifier → FLOW price
  - "Triggering rebalance" … "After Rebalance"        → defines a rebalance window
  - "║   MOET Debt: <value> (BORROWED)"              → actual debt after rebalance

For every rebalance window, the script calculates the expected debt and
reports a mismatch if the relative difference exceeds the tolerance.

NOTE: This first version focuses on auto-borrow tests that follow the
logging conventions in auto_borrow_rebalance_test.cdc. It deliberately
skips auto-balancer verification for brevity.
"""

from __future__ import annotations

import argparse
import re
import sys
import json
from decimal import Decimal, getcontext, ROUND_HALF_EVEN
from dataclasses import dataclass
from typing import List, Optional, Dict, Any
from datetime import datetime

# High precision for financial maths
getcontext().prec = 28
getcontext().rounding = ROUND_HALF_EVEN

@dataclass
class RebalanceEvent:
    line_before: int
    flow_price: Decimal
    expected_debt: Decimal
    actual_debt: Optional[Decimal] = None
    line_after: Optional[int] = None

    def is_verified(self, rel_tol: Decimal, abs_tol: Decimal) -> bool:
        if self.actual_debt is None:
            return False
        diff = abs(self.expected_debt - self.actual_debt)
        return diff <= max(abs_tol, rel_tol * max(abs(self.expected_debt), abs(self.actual_debt)))
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to JSON-serializable dictionary"""
        return {
            'line_before': self.line_before,
            'line_after': self.line_after,
            'flow_price': str(self.flow_price),
            'expected_debt': str(self.expected_debt),
            'actual_debt': str(self.actual_debt) if self.actual_debt else None,
            'difference': str(abs(self.expected_debt - (self.actual_debt or Decimal(0)))),
            'difference_pct': float((abs(self.expected_debt - (self.actual_debt or Decimal(0))) / 
                                   max(self.expected_debt, Decimal("0.00001"))) * 100) if self.actual_debt else 100.0,
            'verified': self.is_verified(Decimal("0.0001"), Decimal("1e-12"))
        }


def parse_decimal(text: str) -> Decimal:
    text = text.replace(',', '')
    return Decimal(text)


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify MOET debt after each auto-borrow rebalance")
    parser.add_argument("log_file", help="Path to test log (e.g. fresh_test_output.log)")
    parser.add_argument("--collateral-factor", type=Decimal, default=Decimal("0.8"), dest="cf",
                        help="Collateral factor used in tests (default 0.8)")
    parser.add_argument("--target-health", type=Decimal, default=Decimal("1.3"), dest="th",
                        help="Target health ratio (default 1.3)")
    parser.add_argument("--tolerance", type=Decimal, default=Decimal("0.0001"), dest="tol",
                        help="Relative tolerance (default 1e-4 → 0.01 %)")
    parser.add_argument("--debug", action="store_true", help="Enable debug output")
    args = parser.parse_args()

    # Regex patterns
    deposit_re = re.compile(r"Creating position with\s*([0-9.,]+)\s*FLOW", re.IGNORECASE)
    # Also look for actual FLOW collateral in comprehensive format
    flow_collateral_re = re.compile(r'(?:║|\\u\{2551\})\s*FLOW Collateral:\s*([0-9.,]+)')
    price_block_start_re = re.compile(r"\[PRICE UPDATE]", re.IGNORECASE)
    token_line_re = re.compile(r"FlowToken", re.IGNORECASE)
    price_line_re = re.compile(r"New Price:\s*([0-9.,]+)")
    rebalance_trigger_re = re.compile(r"Triggering rebalance", re.IGNORECASE)
    # For auto-borrow tests, the position state comes after "Health after rebalance"
    health_after_re = re.compile(r"Health after rebalance:\s*([0-9.]+)")
    position_state_re = re.compile(r"POSITION STATE: After price")
    # Updated pattern: matches both Unicode box-drawing chars and escaped versions
    moet_re = re.compile(r'(?:║|\\u\{2551\})\s*MOET Debt:\s*([0-9.,]+)')
    
    deposit_amount = None
    flow_collateral = None
    flow_price = Decimal("1.0")  # Default price
    
    events = []
    
    with open(args.log_file, "r", encoding="utf-8", errors="ignore") as fh:
        lines = fh.readlines()

    i = 0
    while i < len(lines):
        line = lines[i]
        
        # Check for deposit amount
        match = deposit_re.search(line)
        if match:
            deposit_amount = Decimal(match.group(1).replace(',', ''))
            if args.debug:
                print(f"DEBUG: Found deposit amount: {deposit_amount}")
        
        # Check for FLOW collateral in comprehensive format
        match = flow_collateral_re.search(line)
        if match:
            flow_collateral = Decimal(match.group(1).replace(',', ''))
            if flow_collateral > 0:
                deposit_amount = flow_collateral
                if args.debug:
                    print(f"DEBUG: Found FLOW collateral: {flow_collateral}")
        
        # Track FLOW price changes
        if price_block_start_re.search(line):
            # Look for FlowToken in the next few lines
            j = i + 1
            while j < min(i + 10, len(lines)):
                if token_line_re.search(lines[j]):
                    # Found FlowToken, now look for price
                    k = j + 1
                    while k < min(j + 5, len(lines)):
                        price_match = price_line_re.search(lines[k])
                        if price_match:
                            flow_price = Decimal(price_match.group(1).replace(',', ''))
                            if args.debug:
                                print(f"DEBUG: Found FLOW price: {flow_price}")
                            break
                        k += 1
                    break
                j += 1
        
        # Track rebalancing events
        if rebalance_trigger_re.search(line):
            # Check if this is an auto-balancer rebalance (we should skip these)
            # Look backward for context
            is_auto_balancer = False
            for j in range(max(0, i-10), i):
                if "AUTO-BALANCER STATE:" in lines[j]:
                    is_auto_balancer = True
                    break
            
            if is_auto_balancer:
                if args.debug:
                    print(f"DEBUG: Skipping auto-balancer rebalance at line {i+1}")
                i += 1
                continue
            
            trigger_line = i + 1  # 1-indexed
            
            # For auto-borrow tests, look for position state after health line
            moet_debt = None
            found_line = None
            
            # Search for the position state after rebalance
            j = i + 1
            found_health = False
            while j < min(i + 50, len(lines)):
                # First find "Health after rebalance"
                if health_after_re.search(lines[j]):
                    found_health = True
                
                # Then look for position state
                if found_health and position_state_re.search(lines[j]):
                    # Now find MOET debt in the following lines
                    k = j + 1
                    while k < min(j + 30, len(lines)):
                        match = moet_re.search(lines[k])
                        if match:
                            moet_debt = Decimal(match.group(1).replace(',', ''))
                            found_line = k + 1  # 1-indexed
                            if args.debug:
                                print(f"DEBUG: Found MOET debt at line {found_line}: {moet_debt}")
                            break
                        k += 1
                    break
                j += 1
            
            # If this is a mixed scenario test, try different pattern
            if moet_debt is None:
                j = i + 1
                while j < min(i + 50, len(lines)):
                    if "POSITION STATE: Auto-Borrow" in lines[j]:
                        # Find MOET debt in this block
                        k = j + 1
                        while k < min(j + 30, len(lines)):
                            match = moet_re.search(lines[k])
                            if match:
                                moet_debt = Decimal(match.group(1).replace(',', ''))
                                found_line = k + 1  # 1-indexed
                                if args.debug:
                                    print(f"DEBUG: Found MOET debt in mixed scenario at line {found_line}: {moet_debt}")
                                break
                            k += 1
                        break
                    j += 1
            
            if deposit_amount and flow_price:
                event = {
                    'line_trigger': trigger_line,
                    'line_after': found_line,
                    'flow_price': flow_price,
                    'deposit': deposit_amount,
                    'actual_debt': moet_debt
                }
                events.append(event)
        
        i += 1

    # Process events and calculate expected values
    print(f"\nFound {len(events)} auto-borrow rebalancing events\n")
    
    results = []
    failures = 0
    
    for i, event in enumerate(events):
        # Calculate expected debt
        effective_collateral = event['deposit'] * event['flow_price'] * args.cf
        expected_debt = effective_collateral / args.th
        
        # Create result entry
        result = {
            'event': i + 1,
            'line_trigger': event['line_trigger'],
            'line_after': event['line_after'],
            'flow_price': str(event['flow_price']),
            'deposit': str(event['deposit']),
            'expected_debt': str(expected_debt),
            'actual_debt': str(event['actual_debt']) if event['actual_debt'] else None,
            'verified': False
        }
        
        # Check if actual debt was found and verify
        if event['actual_debt']:
            diff = abs(expected_debt - event['actual_debt'])
            diff_pct = diff / expected_debt
            result['difference'] = str(diff)
            result['difference_pct'] = float(diff_pct * 100)
            
            if diff_pct <= args.tol:
                result['verified'] = True
            else:
                failures += 1
        else:
            result['difference'] = str(expected_debt)
            result['difference_pct'] = 100.0
            failures += 1
        
        results.append(result)
        
        # Print summary
        print(f"Event {i+1}:")
        print(f"  Line: {event['line_trigger']} → {event['line_after'] if event['line_after'] else 'NOT FOUND'}")
        print(f"  FLOW price: {event['flow_price']}")
        print(f"  Deposit: {event['deposit']}")
        print(f"  Expected debt: {expected_debt:.8f}")
        if event['actual_debt']:
            print(f"  Actual debt: {event['actual_debt']:.8f}")
            print(f"  Difference: {result['difference_pct']:.2f}%")
        else:
            print(f"  Actual debt: NOT FOUND")
        print(f"  Verified: {'✅' if result['verified'] else '❌'}")
        print()
    
    # Save results to JSON
    output = {
        'test_file': args.log_file,
        'timestamp': datetime.now().isoformat(),
        'parameters': {
            'collateral_factor': str(args.cf),
            'target_health': str(args.th),
            'tolerance': str(args.tol)
        },
        'summary': {
            'total_events': len(events),
            'verified': len(events) - failures,
            'failed': failures,
            'success_rate': f"{(len(events) - failures) / len(events) * 100:.1f}%" if events else "N/A"
        },
        'events': results
    }
    
    with open('auto_borrow_balance_verification.json', 'w') as f:
        json.dump(output, f, indent=2)
    
    # Final summary
    print("=" * 60)
    print("AUTO-BORROW REBALANCE VERIFICATION RESULTS")
    print("=" * 60)
    print(f"Total rebalancing events: {len(events)}")
    print(f"Successfully verified: {len(events) - failures}")
    print(f"Failed verification: {failures}")
    if events:
        print(f"Success rate: {(len(events) - failures) / len(events) * 100:.1f}%")
    print(f"\nResults saved to: auto_borrow_balance_verification.json")
    
    sys.exit(0 if failures == 0 else 1)


if __name__ == "__main__":
    main() 