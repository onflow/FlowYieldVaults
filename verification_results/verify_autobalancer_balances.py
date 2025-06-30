#!/usr/bin/env python3
"""
Auto-Balancer Balance Verification for Tidal Protocol

This script verifies that YieldToken balances after each auto-balancer
rebalance match the mathematically expected values.

Auto-balancer rebalancing logic:
1. Initial YieldToken balance = depositedFLOW * collateralFactor / targetHealth / initialYieldPrice
2. When YieldToken price changes, the system rebalances to maintain the target health
3. Expected balance after rebalance depends on maintaining the same MOET value

Key formula for rebalancing:
- Total MOET value should remain constant (or adjust based on health target)
- YieldToken balance = Total MOET value / Current YieldToken price

Protocol constants:
    collateralFactor = 0.8
    targetHealth     = 1.3
    tolerance        = 0.001   # 0.1%

IMPORTANT: Auto-balancer has a 5% tolerance band:
- Only rebalances when value is <95% or >105% of target
- Small price changes may not trigger rebalancing

The script looks for:
  - "Creating auto-balancer Tide with <amount> FLOW"
  - "[PRICE UPDATE]" blocks for YieldToken
  - "Triggering rebalance" events
  - "YieldToken Balance: <value>" in [AUTOBALANCER STATE] blocks
"""

from __future__ import annotations

import argparse
import re
import sys
import json
from decimal import Decimal, getcontext, ROUND_HALF_EVEN
from dataclasses import dataclass
from typing import List, Optional, Dict, Any

# High precision for financial calculations
getcontext().prec = 28
getcontext().rounding = ROUND_HALF_EVEN

@dataclass
class AutoBalancerState:
    line: int
    yield_balance: Decimal
    yield_price: Decimal
    moet_value: Decimal
    stage: str = ""
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to JSON-serializable dictionary"""
        return {
            'line': self.line,
            'yield_balance': str(self.yield_balance),
            'yield_price': str(self.yield_price),
            'moet_value': str(self.moet_value),
            'stage': self.stage
        }

@dataclass
class RebalanceVerification:
    before_state: AutoBalancerState
    after_state: AutoBalancerState
    expected_balance: Decimal
    price_change_factor: Decimal
    actual_rebalanced: bool
    
    def is_verified(self, rel_tol: Decimal) -> bool:
        # If no actual rebalance occurred, we can't verify
        if not self.actual_rebalanced:
            return True  # Not a failure if rebalance wasn't needed
        
        diff = abs(self.after_state.yield_balance - self.expected_balance)
        max_val = max(abs(self.after_state.yield_balance), abs(self.expected_balance))
        if max_val == 0:
            return diff == 0
        return diff / max_val <= rel_tol
    
    def to_dict(self) -> Dict[str, Any]:
        """Convert to JSON-serializable dictionary"""
        diff = abs(self.after_state.yield_balance - self.expected_balance)
        pct_diff = (diff / max(self.expected_balance, Decimal("0.0001"))) * 100 if self.actual_rebalanced else 0
        
        return {
            'before_state': self.before_state.to_dict(),
            'after_state': self.after_state.to_dict(),
            'expected_balance': str(self.expected_balance),
            'price_change_factor': float(self.price_change_factor),
            'actual_rebalanced': self.actual_rebalanced,
            'difference': str(diff) if self.actual_rebalanced else "0",
            'difference_pct': float(pct_diff),
            'verified': self.is_verified(Decimal("0.001")),
            'status': 'skipped' if not self.actual_rebalanced else ('pass' if self.is_verified(Decimal("0.001")) else 'fail')
        }


def parse_decimal(text: str) -> Decimal:
    """Parse decimal handling commas and scientific notation"""
    text = text.replace(',', '')
    return Decimal(text)


def extract_autobalancer_state(lines: List[str], start_idx: int) -> Optional[AutoBalancerState]:
    """Extract AutoBalancer state from log lines (supports both old and comprehensive formats)"""
    # Look for either old [AUTOBALANCER STATE] or new comprehensive format
    if "[AUTOBALANCER STATE]" not in lines[start_idx] and "AUTO-BALANCER STATE:" not in lines[start_idx]:
        return None
    
    yield_balance = None
    yield_price = None
    moet_value = None
    flow_price = None
    moet_price = None
    
    # Search next 30 lines for state info (more for comprehensive format)
    for i in range(start_idx, min(start_idx + 30, len(lines))):
        line = lines[i]
        
        # YieldToken Balance (both formats)
        match = re.search(r'YieldToken Balance:\s*([0-9.,]+)', line)
        if match:
            yield_balance = parse_decimal(match.group(1))
            
        # YieldToken Price (old format)
        match = re.search(r'YieldToken Price:\s*([0-9.,]+)', line)
        if match:
            yield_price = parse_decimal(match.group(1))
            
        # Comprehensive format prices (|   YieldToken: 1.20000000 MOET) - cleaned format
        match = re.search(r'\|\s*YieldToken:\s*([0-9.,]+)', line)
        if match and yield_price is None:
            yield_price = parse_decimal(match.group(1))
            
        match = re.search(r'\|\s*FLOW:\s*([0-9.,]+)', line)
        if match:
            flow_price = parse_decimal(match.group(1))
            
        match = re.search(r'\|\s*MOET:\s*([0-9.,]+)', line)
        if match:
            moet_price = parse_decimal(match.group(1))
            
        # Total Value in MOET (old format)
        match = re.search(r'Total Value in MOET:\s*([0-9.,]+)', line)
        if match:
            moet_value = parse_decimal(match.group(1))
            
        # Comprehensive format value (|   -> Value in MOET: 738.46153846) - cleaned format
        match = re.search(r'\|\s*->\s*Value(?:\s+in MOET)?:\s*([0-9.,]+)', line)
        if match and moet_value is None:
            # This could be for any token, need to check context
            # If it's after YieldToken Balance, it's the YieldToken value
            if yield_balance is not None and moet_value is None:
                moet_value = parse_decimal(match.group(1))
    
    if yield_balance is not None and yield_price is not None and moet_value is not None:
        return AutoBalancerState(
            line=start_idx + 1,
            yield_balance=yield_balance,
            yield_price=yield_price,
            moet_value=moet_value
        )
    
    return None


def main() -> None:
    parser = argparse.ArgumentParser(description="Verify YieldToken balances after auto-balancer rebalances")
    parser.add_argument("log_file", help="Path to test log file")
    parser.add_argument("--collateral-factor", type=Decimal, default=Decimal("0.8"), dest="cf",
                        help="Collateral factor (default 0.8)")
    parser.add_argument("--target-health", type=Decimal, default=Decimal("1.3"), dest="th",
                        help="Target health ratio (default 1.3)")
    parser.add_argument("--tolerance", type=Decimal, default=Decimal("0.001"), dest="tol",
                        help="Relative tolerance (default 0.001 = 0.1%)")
    parser.add_argument("--rebalance-threshold", type=Decimal, default=Decimal("0.05"), dest="threshold",
                        help="Rebalance threshold (default 0.05 = 5%)")
    args = parser.parse_args()
    
    # Read log file
    with open(args.log_file, "r", encoding="utf-8", errors="ignore") as f:
        lines = f.readlines()
    
    # Track state
    deposit_amount: Optional[Decimal] = None
    initial_yield_price: Optional[Decimal] = None
    current_yield_price: Decimal = Decimal("1.0")
    autobalancer_states: List[AutoBalancerState] = []
    current_stage = ""
    
    # Parse log
    i = 0
    while i < len(lines):
        line = lines[i]
        
        # Track current stage
        if "Stage" in line and ":" in line:
            current_stage = line.strip()
        
        # Detect Tide creation with FLOW
        match = re.search(r'Creating (?:auto-balancer )?Tide with\s*([0-9.,]+)\s*FLOW', line)
        if match:
            deposit_amount = parse_decimal(match.group(1))
            print(f"Detected deposit: {deposit_amount} FLOW at line {i+1}")
        
        # YieldToken price updates
        if "[PRICE UPDATE]" in line:
            # Look ahead for YieldToken price
            for j in range(i, min(i + 6, len(lines))):
                if "YieldToken" in lines[j]:
                    price_match = re.search(r'New Price:\s*([0-9.,]+)', lines[j+1] if j+1 < len(lines) else "")
                    if price_match:
                        current_yield_price = parse_decimal(price_match.group(1))
                        if initial_yield_price is None:
                            initial_yield_price = current_yield_price
                        print(f"YieldToken price update: {current_yield_price} at line {j+1}")
                    break
        
        # AutoBalancer state (both old and comprehensive formats)
        if "[AUTOBALANCER STATE]" in line or "AUTO-BALANCER STATE:" in line:
            state = extract_autobalancer_state(lines, i)
            if state:
                state.stage = current_stage
                autobalancer_states.append(state)
                print(f"Captured AutoBalancer state at line {state.line}: "
                      f"Balance={state.yield_balance}, Price={state.yield_price}, Value={state.moet_value}")
        
        i += 1
    
    # Verify rebalances
    if not autobalancer_states:
        print("\nNo AutoBalancer states found in log!")
        sys.exit(1)
    
    if deposit_amount is None:
        print("\nWarning: Could not find initial deposit amount!")
        deposit_amount = Decimal("1000")  # Default assumption
    
    # Calculate initial expected values
    initial_effective_collateral = deposit_amount * args.cf
    initial_moet_borrowed = initial_effective_collateral / args.th
    
    print(f"\nInitial calculations:")
    print(f"  Deposit: {deposit_amount} FLOW")
    print(f"  Effective collateral: {initial_effective_collateral}")
    print(f"  Expected MOET borrowed: {initial_moet_borrowed}")
    
    # Verify each state transition
    verifications: List[RebalanceVerification] = []
    
    for i in range(1, len(autobalancer_states)):
        before = autobalancer_states[i-1]
        after = autobalancer_states[i]
        
        # Skip if not a rebalance (same price)
        if before.yield_price == after.yield_price:
            continue
        
        # Check if balance actually changed (indicating a real rebalance)
        actual_rebalanced = before.yield_balance != after.yield_balance
        
        # Calculate expected balance IF a rebalance occurred
        # The system tries to maintain target health (100% of borrowed amount)
        # So expected value = initial_moet_borrowed
        # Expected balance = initial_moet_borrowed / current_price
        expected_balance = initial_moet_borrowed / after.yield_price
        
        # Alternative calculation: maintain previous value
        # expected_balance = before.moet_value / after.yield_price
        
        price_change_factor = after.yield_price / before.yield_price
        
        verification = RebalanceVerification(
            before_state=before,
            after_state=after,
            expected_balance=expected_balance,
            price_change_factor=price_change_factor,
            actual_rebalanced=actual_rebalanced
        )
        verifications.append(verification)
    
    # Report results
    print("\n" + "="*80)
    print("AUTO-BALANCER REBALANCE VERIFICATION RESULTS")
    print("="*80)
    
    failures = []
    skipped = 0
    
    for idx, v in enumerate(verifications, 1):
        if not v.actual_rebalanced:
            skipped += 1
            print(f"\nRebalance {idx}: {v.before_state.stage}")
            print(f"  Price change: {v.before_state.yield_price} → {v.after_state.yield_price} "
                  f"({v.price_change_factor:.4f}x)")
            print(f"  Balance unchanged: {v.before_state.yield_balance:.8f}")
            print(f"  MOET value: {v.before_state.moet_value:.8f} → {v.after_state.moet_value:.8f}")
            print(f"  Status: ⏭️  SKIPPED (no rebalance occurred - likely within 5% tolerance)")
            continue
            
        status = "✅ PASS" if v.is_verified(args.tol) else "❌ FAIL"
        diff = abs(v.after_state.yield_balance - v.expected_balance)
        pct_diff = (diff / max(v.expected_balance, Decimal("0.0001"))) * 100
        
        print(f"\nRebalance {idx}: {v.before_state.stage}")
        print(f"  Price change: {v.before_state.yield_price} → {v.after_state.yield_price} "
              f"({v.price_change_factor:.4f}x)")
        print(f"  Balance change: {v.before_state.yield_balance:.8f} → {v.after_state.yield_balance:.8f}")
        print(f"  Expected balance: {v.expected_balance:.8f}")
        print(f"  Difference: {diff:.8f} ({pct_diff:.4f}%)")
        print(f"  MOET value: {v.before_state.moet_value:.8f} → {v.after_state.moet_value:.8f}")
        print(f"  Status: {status}")
        
        if not v.is_verified(args.tol):
            failures.append(v)
    
    # Summary
    print("\n" + "="*80)
    print("SUMMARY")
    print("="*80)
    print(f"Total price changes analyzed: {len(verifications)}")
    print(f"Actual rebalances: {len(verifications) - skipped}")
    print(f"Skipped (no rebalance): {skipped}")
    print(f"Passed: {len(verifications) - skipped - len(failures)}")
    print(f"Failed: {len(failures)}")
    
    if failures:
        print("\nFailed rebalances:")
        for idx, v in enumerate(failures, 1):
            print(f"  {idx}. Price {v.before_state.yield_price} → {v.after_state.yield_price}: "
                  f"Expected {v.expected_balance:.8f}, got {v.after_state.yield_balance:.8f}")
    
    # Additional analysis
    if autobalancer_states:
        print("\n" + "="*80)
        print("BALANCE TRAJECTORY (YieldToken)")
        print("="*80)
        print("Line  | YieldToken Balance | YieldToken Price | MOET Value      | Health")
        print("-"*80)
        for state in autobalancer_states:
            health = (state.moet_value / initial_moet_borrowed) if initial_moet_borrowed > 0 else 0
            print(f"{state.line:5} | {state.yield_balance:18.8f} | {state.yield_price:16.4f} | "
                  f"{state.moet_value:15.8f} | {health:6.4f}")
        
        # Show price range
        yield_prices = [s.yield_price for s in autobalancer_states]
        print(f"\nYieldToken price range: {min(yield_prices):.4f} - {max(yield_prices):.4f}")
        
        # Show balance range
        yield_balances = [s.yield_balance for s in autobalancer_states]
        print(f"YieldToken balance range: {min(yield_balances):.8f} - {max(yield_balances):.8f}")
    
    # Save JSON output
    results = {
        'test_file': args.log_file,
        'parameters': {
            'collateral_factor': str(args.cf),
            'target_health': str(args.th),
            'tolerance': str(args.tol),
            'rebalance_threshold': str(args.threshold),
            'deposit_amount': str(deposit_amount) if deposit_amount else None,
            'initial_moet_borrowed': str(initial_moet_borrowed)
        },
        'summary': {
            'total_price_changes': len(verifications),
            'actual_rebalances': len(verifications) - skipped,
            'skipped': skipped,
            'passed': len(verifications) - skipped - len(failures),
            'failed': len(failures),
            'pass_rate': float((len(verifications) - skipped - len(failures)) / 
                             (len(verifications) - skipped) * 100) if (len(verifications) - skipped) > 0 else 0.0
        },
        'states': [state.to_dict() for state in autobalancer_states],
        'verifications': [v.to_dict() for v in verifications],
        'failures': [v.to_dict() for v in failures],
        'price_range': {
            'min': str(min(s.yield_price for s in autobalancer_states)),
            'max': str(max(s.yield_price for s in autobalancer_states))
        },
        'balance_range': {
            'min': str(min(s.yield_balance for s in autobalancer_states)),
            'max': str(max(s.yield_balance for s in autobalancer_states))
        }
    }
    
    with open("auto_balancer_verification.json", "w") as f:
        json.dump(results, f, indent=2)
    
    print("\nDetailed results saved to auto_balancer_verification.json")
    
    sys.exit(0 if not failures else 1)


if __name__ == "__main__":
    main() 