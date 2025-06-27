#!/usr/bin/env python3
"""
Deep Mathematical Verification for Tidal Protocol
Focuses on finding actual calculation errors, not floating-point precision issues
Production-grade version with proper financial precision
"""

import re
import sys
from decimal import Decimal, getcontext, ROUND_HALF_EVEN
from dataclasses import dataclass
from typing import List, Dict, Optional, Tuple
import json

# Set high precision for financial calculations
getcontext().prec = 28
getcontext().rounding = ROUND_HALF_EVEN

@dataclass
class Finding:
    severity: str  # ERROR, WARNING, INFO
    line: int
    issue: str
    details: str

def is_close(a: Decimal, b: Decimal, rel_tol=Decimal('1e-8'), abs_tol=Decimal('1e-12')) -> bool:
    """Compare two decimals with both relative and absolute tolerance"""
    return abs(a - b) <= max(abs_tol, rel_tol * max(abs(a), abs(b)))

def parse_decimal(value_str: str) -> Decimal:
    """Parse a decimal value, handling commas and scientific notation"""
    value_str = value_str.replace(',', '')
    if 'e' in value_str.lower():
        return Decimal(value_str)
    return Decimal(value_str)

class DeepVerifier:
    def __init__(self, log_file: str):
        self.log_file = log_file
        self.findings: List[Finding] = []
        self.current_prices: Dict[str, Decimal] = {}
        self.health_history: List[Tuple[int, Decimal, str]] = []  # (line, health, context)
        self.balance_history: List[Tuple[int, Decimal, str]] = []  # (line, balance, context)
        
    def analyze(self):
        """Perform deep analysis of the log file"""
        with open(self.log_file, 'r') as f:
            lines = f.readlines()
        
        current_test = ""
        current_stage = ""
        
        for i, line in enumerate(lines, 1):
            # Track context
            if "Running test:" in line:
                current_test = line.strip()
            if "Stage" in line and ":" in line:
                current_stage = line.strip()
                
            # Price updates
            if "[PRICE UPDATE]" in line and i+3 < len(lines):
                self._analyze_price_update(i, lines[i-1:i+4])
                
            # Health checks
            health_match = re.search(r'(?:Health|health).*?:\s*([0-9.,]+)', line)
            if health_match:
                health = parse_decimal(health_match.group(1))
                self.health_history.append((i, health, line.strip()))
                self._check_health_logic(i, health, line)
                
            # Balance tracking - populate balance_history
            balance_match = re.search(r'Balance:\s*([0-9.,]+)', line)
            if balance_match:
                balance = parse_decimal(balance_match.group(1))
                token_type = "YieldToken" if "YieldToken" in line else "Unknown"
                self.balance_history.append((i, balance, f"{token_type} - {current_stage}"))
                
            # AutoBalancer calculations
            if "[AUTOBALANCER STATE]" in line and i+10 < len(lines):
                self._analyze_autobalancer_state(i, lines[i-1:i+10])
                
            # Balance changes
            if "Balance DECREASED by:" in line or "Balance INCREASED by:" in line:
                self._check_balance_change(i, line)
                
            # Rebalancing logic
            if "Triggering rebalance" in line or "Double rebalance attempt" in line:
                self._check_rebalancing_context(i, lines, current_stage)
                
            # Calculation verification
            if "[CALCULATION]" in line and i+1 < len(lines):
                self._verify_calculation_line(i, lines[i-1:i+2])
                
            # Check for errors or panics - more selective
            if ("error" in line.lower() or "panic" in line.lower()) and "LOG:" not in line and "Test" not in line:
                if not any(safe_word in line.lower() for safe_word in ["error:", "no error", "without error"]):
                    self.findings.append(Finding("WARNING", i, "Potential error", line.strip()))
                    
            # Zero values that might be problematic
            if "Balance: 0.00000000" in line and "YieldToken" in line:
                self._check_zero_balance_context(i, lines, current_stage)
                
    def _analyze_price_update(self, line_num: int, context: List[str]):
        """Analyze price updates for anomalies"""
        price_match = None
        token_match = None
        
        # Search across multiple lines
        for ctx_line in context:
            if not price_match:
                price_match = re.search(r'New Price:\s*([0-9.,]+)', ctx_line)
            if not token_match:
                token_match = re.search(r'Token Identifier:.*?\.([^.]+)\.Vault', ctx_line)
        
        if price_match and token_match:
            price = parse_decimal(price_match.group(1))
            token = token_match.group(1)
            
            # Check for extreme prices
            if price == 0:
                self.findings.append(Finding("WARNING", line_num, "Zero price set", 
                    f"{token} price set to 0 - this will cause division by zero in calculations"))
            elif price > 1000:
                self.findings.append(Finding("INFO", line_num, "Extreme high price", 
                    f"{token} price set to {price} - may cause overflow in calculations"))
            elif price < Decimal('0.00001') and price > 0:
                self.findings.append(Finding("INFO", line_num, "Micro price", 
                    f"{token} price set to {price} - may cause precision issues"))
                    
            self.current_prices[token] = price
            
    def _check_health_logic(self, line_num: int, health: Decimal, line: str):
        """Check if health values follow protocol logic"""
        # Protocol constants
        MIN_HEALTH = Decimal('1.1')
        TARGET_HEALTH = Decimal('1.3')
        MAX_HEALTH = Decimal('1.5')
        
        # Check for impossible health values
        if health < 0:
            self.findings.append(Finding("ERROR", line_num, "Negative health", 
                f"Health ratio is negative: {health}"))
        elif health > 1000000:
            self.findings.append(Finding("ERROR", line_num, "Impossible health value", 
                f"Health ratio impossibly high: {health}"))
            
        # Check rebalancing logic - improved version
        if "after" in line.lower() and "rebalance" in line.lower():
            # Find the corresponding "before" health - look backward
            before_health = None
            before_line = None
            
            for j in range(len(self.health_history)-2, max(0, len(self.health_history)-20), -1):
                prev_line, prev_health, prev_context = self.health_history[j]
                if "before" in prev_context.lower() and "rebalance" in prev_context.lower():
                    before_health = prev_health
                    before_line = prev_line
                    break
                    
            if before_health is not None:
                # Check rebalancing effectiveness
                if before_health < MIN_HEALTH and health < MIN_HEALTH:
                    self.findings.append(Finding("WARNING", line_num, "Ineffective rebalance", 
                        f"Health still below MIN_HEALTH ({MIN_HEALTH}) after rebalance: {before_health} → {health}"))
                elif before_health > MAX_HEALTH and health > TARGET_HEALTH:
                    self.findings.append(Finding("WARNING", line_num, "Incomplete rebalance", 
                        f"Health not reduced to TARGET ({TARGET_HEALTH}) from {before_health} → {health}"))
                        
                # Check direction
                direction_correct = (
                    (before_health < MIN_HEALTH and health > before_health) or
                    (before_health > MAX_HEALTH and health < before_health) or
                    (MIN_HEALTH <= before_health <= MAX_HEALTH)
                )
                if not direction_correct:
                    self.findings.append(Finding("WARNING", line_num, "Wrong rebalance direction",
                        f"Health moved wrong direction: {before_health} → {health}"))
                    
    def _analyze_autobalancer_state(self, line_num: int, context: List[str]):
        """Analyze AutoBalancer state for calculation errors"""
        balance = None
        stated_value = None
        
        # Join context for multiline search
        context_text = ''.join(context)
        
        # Extract balance
        balance_match = re.search(r'YieldToken Balance:\s*([0-9.,]+)', context_text)
        if balance_match:
            balance = parse_decimal(balance_match.group(1))
            
        # Extract stated value
        value_match = re.search(r'Total Value in MOET:\s*([0-9.,]+)', context_text)
        if value_match:
            stated_value = parse_decimal(value_match.group(1))
            
        # Also check for inline calculation
        calc_match = re.search(r'\[CALCULATION\].*?([0-9.,]+)\s*\*\s*([0-9.,]+)\s*=\s*([0-9.,]+)', context_text)
        if calc_match:
            balance = parse_decimal(calc_match.group(1))
            price = parse_decimal(calc_match.group(2))
            stated_value = parse_decimal(calc_match.group(3))
            self.current_prices["YieldToken"] = price
                
        if balance is not None and stated_value is not None and "YieldToken" in self.current_prices:
            expected_value = balance * self.current_prices["YieldToken"]
            
            # Guard against division by zero
            if expected_value == 0:
                if stated_value != 0:
                    self.findings.append(Finding("ERROR", line_num, "Value mismatch with zero balance", 
                        f"Balance is 0 but stated value is {stated_value}"))
            else:
                # Check for significant discrepancies using is_close
                if not is_close(expected_value, stated_value, rel_tol=Decimal('0.0001')):  # 0.01% tolerance
                    error_pct = abs(expected_value - stated_value) / expected_value * 100
                    self.findings.append(Finding("ERROR", line_num, "Calculation mismatch", 
                        f"AutoBalancer value calculation off by {error_pct:.4f}%: {balance} * {self.current_prices.get('YieldToken')} = {expected_value}, stated: {stated_value}"))
                        
    def _check_balance_change(self, line_num: int, line: str):
        """Verify balance change calculations"""
        change_match = re.search(r'by:\s*([0-9.,]+)', line)
        if change_match:
            stated_change = parse_decimal(change_match.group(1))
            
            # Look for before/after balances in recent history
            if len(self.balance_history) >= 2:
                # Find most recent two balances
                recent_balances = sorted(self.balance_history[-10:], key=lambda x: x[0])
                
                if len(recent_balances) >= 2:
                    before = recent_balances[-2][1]
                    after = recent_balances[-1][1]
                    calculated_change = abs(after - before)
                    
                    if not is_close(calculated_change, stated_change, rel_tol=Decimal('0.001')):  # 0.1% tolerance
                        self.findings.append(Finding("WARNING", line_num, "Balance change mismatch", 
                            f"Stated change {stated_change} doesn't match calculated {calculated_change} (before: {before}, after: {after})"))
                        
    def _check_rebalancing_context(self, line_num: int, lines: List[str], stage: str):
        """Check if rebalancing is happening at appropriate times"""
        MIN_HEALTH = Decimal('1.1')
        MAX_HEALTH = Decimal('1.5')
        
        # Look for recent health info in the last 10 lines
        for i in range(max(0, line_num-10), line_num):
            if i < len(lines):
                line = lines[i]
                health_match = re.search(r'Health.*?:\s*([0-9.,]+)', line)
                if health_match:
                    health = parse_decimal(health_match.group(1))
                    if MIN_HEALTH <= health <= MAX_HEALTH:
                        self.findings.append(Finding("INFO", line_num, "Rebalance in target range", 
                            f"Rebalancing triggered with health {health} already in target range [{MIN_HEALTH}, {MAX_HEALTH}]"))
                                
    def _verify_calculation_line(self, line_num: int, context: List[str]):
        """Verify explicit calculations"""
        calc_text = ''.join(context)
        calc_match = re.search(r'([0-9.,]+)\s*\*\s*([0-9.,]+)\s*=\s*([0-9.,]+)', calc_text)
        
        if calc_match:
            a = parse_decimal(calc_match.group(1))
            b = parse_decimal(calc_match.group(2))
            stated_result = parse_decimal(calc_match.group(3))
            actual_result = a * b
            
            # Check for significant errors using is_close
            if not is_close(actual_result, stated_result, rel_tol=Decimal('0.00001')):  # 0.001% tolerance
                if actual_result > 0:
                    error_pct = abs(actual_result - stated_result) / actual_result * 100
                    self.findings.append(Finding("WARNING", line_num, "Calculation precision", 
                        f"Calculation {a} * {b} = {stated_result} (actual: {actual_result}, {error_pct:.6f}% error)"))
                        
    def _check_zero_balance_context(self, line_num: int, lines: List[str], stage: str):
        """Check context when balance goes to zero"""
        # Look for crash scenario indicators
        crash_indicators = ["crash", "extreme", "zero price", "0.01", "0.001"]
        context_window = 20
        
        crash_found = False
        for i in range(max(0, line_num-context_window), min(line_num+5, len(lines))):
            if i < len(lines):
                line_lower = lines[i].lower()
                if any(indicator in line_lower for indicator in crash_indicators):
                    crash_found = True
                    break
                    
        if not crash_found and "concurrent" not in stage.lower():
            self.findings.append(Finding("WARNING", line_num, "Unexpected zero balance", 
                f"AutoBalancer balance went to zero without obvious crash scenario"))
                    
    def generate_report(self):
        """Generate detailed findings report"""
        print("=" * 80)
        print("DEEP MATHEMATICAL VERIFICATION REPORT")
        print("=" * 80)
        
        # Categorize findings
        errors = [f for f in self.findings if f.severity == "ERROR"]
        warnings = [f for f in self.findings if f.severity == "WARNING"]
        info = [f for f in self.findings if f.severity == "INFO"]
        
        print(f"\nTotal findings: {len(self.findings)}")
        print(f"  Errors: {len(errors)}")
        print(f"  Warnings: {len(warnings)}")
        print(f"  Info: {len(info)}")
        
        if errors:
            print("\n" + "="*80)
            print("ERRORS (Must Fix):")
            print("="*80)
            for f in errors:
                print(f"\n❌ Line {f.line}: {f.issue}")
                print(f"   {f.details}")
                
        if warnings:
            print("\n" + "="*80)
            print("WARNINGS (Should Investigate):")
            print("="*80)
            for f in warnings[:10]:  # First 10
                print(f"\n⚠️  Line {f.line}: {f.issue}")
                print(f"   {f.details}")
            if len(warnings) > 10:
                print(f"\n... and {len(warnings)-10} more warnings")
                
        # Summary of health values
        if self.health_history:
            print("\n" + "="*80)
            print("HEALTH RATIO SUMMARY:")
            print("="*80)
            
            healths = [h[1] for h in self.health_history]
            print(f"Total health checks: {len(healths)}")
            print(f"Min: {min(healths)}")
            print(f"Max: {max(healths)}")
            print(f"Critical (<0.1): {len([h for h in healths if h < Decimal('0.1')])}")
            print(f"Below min (0.1-1.1): {len([h for h in healths if Decimal('0.1') <= h < Decimal('1.1')])}")
            print(f"In range (1.1-1.5): {len([h for h in healths if Decimal('1.1') <= h <= Decimal('1.5')])}")
            print(f"Above max (>1.5): {len([h for h in healths if h > Decimal('1.5')])}")
            
        # Balance history summary
        if self.balance_history:
            print("\n" + "="*80)
            print("BALANCE HISTORY SUMMARY:")
            print("="*80)
            
            balances = [b[1] for b in self.balance_history]
            non_zero_balances = [b for b in balances if b > 0]
            
            print(f"Total balance checks: {len(balances)}")
            print(f"Zero balances: {len([b for b in balances if b == 0])}")
            if non_zero_balances:
                print(f"Min non-zero: {min(non_zero_balances)}")
                print(f"Max: {max(balances)}")
            
        # Price extremes
        if self.current_prices:
            print("\n" + "="*80)
            print("PRICE EXTREMES TESTED:")
            print("="*80)
            for token, price in self.current_prices.items():
                if price == 0 or price > 100 or price < Decimal('0.01'):
                    print(f"{token}: {price}")
                    
        return len(errors) == 0

def main():
    log_file = sys.argv[1] if len(sys.argv) > 1 else "full_test_output.log"
    
    verifier = DeepVerifier(log_file)
    print(f"Analyzing {log_file}...")
    verifier.analyze()
    
    success = verifier.generate_report()
    
    # Save findings
    with open("deep_verification_report.json", "w") as f:
        json.dump({
            "success": success,
            "findings": [
                {
                    "severity": f.severity,
                    "line": f.line,
                    "issue": f.issue,
                    "details": f.details
                }
                for f in verifier.findings
            ],
            "summary": {
                "total_findings": len(verifier.findings),
                "errors": len([f for f in verifier.findings if f.severity == "ERROR"]),
                "warnings": len([f for f in verifier.findings if f.severity == "WARNING"]),
                "info": len([f for f in verifier.findings if f.severity == "INFO"])
            }
        }, f, indent=2)
    
    print("\nDetailed findings saved to deep_verification_report.json")
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main() 