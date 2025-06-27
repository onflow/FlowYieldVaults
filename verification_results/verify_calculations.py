#!/usr/bin/env python3
"""
Comprehensive Mathematical Verification for Tidal Protocol Test Logs
Parses test output and verifies all calculations for correctness
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
class Calculation:
    line_number: int
    description: str
    formula: str
    operand1: Decimal
    operand2: Decimal
    expected_result: Decimal
    actual_result: Optional[Decimal] = None
    error: Optional[str] = None

@dataclass
class PriceUpdate:
    line_number: int
    token: str
    price: Decimal

@dataclass
class HealthCheck:
    line_number: int
    position_id: int
    health: Decimal
    stage: str
    full_line: str  # Store full line for better context

@dataclass
class BalanceCheck:
    line_number: int
    balance: Decimal
    token: str
    stage: str

def is_close(a: Decimal, b: Decimal, rel_tol=Decimal('1e-8'), abs_tol=Decimal('1e-12')) -> bool:
    """Compare two decimals with both relative and absolute tolerance"""
    return abs(a - b) <= max(abs_tol, rel_tol * max(abs(a), abs(b)))

class TestLogVerifier:
    def __init__(self, log_file: str):
        self.log_file = log_file
        self.calculations: List[Calculation] = []
        self.price_updates: List[PriceUpdate] = []
        self.health_checks: List[HealthCheck] = []
        self.balance_checks: List[BalanceCheck] = []
        self.errors: List[str] = []
        self.current_prices: Dict[str, Decimal] = {}
        
        # Improved regex patterns - more flexible with whitespace
        self.price_pattern = re.compile(r'\[PRICE UPDATE\]')
        self.token_pattern = re.compile(r'Token Identifier:\s*([^\s]+)')
        self.price_value_pattern = re.compile(r'New Price:\s*([0-9.,]+)')
        self.calc_pattern = re.compile(r'\[CALCULATION\].*?([0-9.,]+)\s*\*\s*([0-9.,]+)\s*=\s*([0-9.,]+)')
        self.health_pattern = re.compile(r'(?:Health|health).*?:\s*([0-9.,]+)')
        self.balance_pattern = re.compile(r'(?:Balance|balance).*?:\s*([0-9.,]+)')
        self.position_health_pattern = re.compile(r'Position ID:\s*(\d+).*?Health Ratio:\s*([0-9.,]+)', re.DOTALL)
        self.autobalancer_state_pattern = re.compile(r'\[AUTOBALANCER STATE\].*?YieldToken Balance:\s*([0-9.,]+).*?Total Value in MOET:\s*([0-9.,]+)', re.DOTALL)
        
        # Token address to name mapping
        self.token_mapping = {
            'FlowToken': 'FLOW',
            'YieldToken': 'YieldToken',
            'MOET': 'MOET'
        }
        
    def parse_decimal(self, value_str: str) -> Decimal:
        """Parse a decimal value, handling commas and scientific notation"""
        # Remove commas
        value_str = value_str.replace(',', '')
        # Handle scientific notation
        if 'e' in value_str.lower():
            return Decimal(value_str)
        return Decimal(value_str)
        
    def parse_log(self):
        """Parse the log file and extract all calculations and values"""
        with open(self.log_file, 'r') as f:
            lines = f.readlines()
            
        current_stage = ""
        i = 0
        while i < len(lines):
            line = lines[i].strip()
            
            # Track current stage
            if "Stage" in line and ":" in line:
                current_stage = line
            
            # Price updates - look ahead for token and price
            if "[PRICE UPDATE]" in line:
                token_name = None
                price = None
                
                # Search next 5 lines for token identifier and price
                for j in range(i, min(i+5, len(lines))):
                    token_match = self.token_pattern.search(lines[j])
                    if token_match:
                        token_id = token_match.group(1)
                        # Map token address to name
                        for key, name in self.token_mapping.items():
                            if key in token_id:
                                token_name = name
                                break
                        if not token_name:
                            token_name = token_id
                            
                    price_match = self.price_value_pattern.search(lines[j])
                    if price_match:
                        price = self.parse_decimal(price_match.group(1))
                        
                if token_name and price:
                    self.current_prices[token_name] = price
                    self.price_updates.append(PriceUpdate(i+1, token_name, price))
            
            # Value calculations - check current line and next 3 lines
            if "[CALCULATION]" in line:
                for j in range(i, min(i+4, len(lines))):
                    calc_match = self.calc_pattern.search(lines[j])
                    if calc_match:
                        balance = self.parse_decimal(calc_match.group(1))
                        price = self.parse_decimal(calc_match.group(2))
                        result = self.parse_decimal(calc_match.group(3))
                        
                        calc = Calculation(
                            line_number=j+1,
                            description="Total Value calculation",
                            formula=f"{balance} * {price}",
                            operand1=balance,
                            operand2=price,
                            expected_result=result
                        )
                        self.verify_calculation(calc)
                        self.calculations.append(calc)
                        break
            
            # Health checks
            health_match = self.health_pattern.search(line)
            if health_match:
                health = self.parse_decimal(health_match.group(1))
                self.health_checks.append(HealthCheck(i+1, 0, health, current_stage, line))
                
            # Balance checks
            balance_match = self.balance_pattern.search(line)
            if balance_match and "YieldToken" in line:
                balance = self.parse_decimal(balance_match.group(1))
                self.balance_checks.append(BalanceCheck(i+1, balance, "YieldToken", current_stage))
            
            # AutoBalancer state with calculations
            if "[AUTOBALANCER STATE]" in line:
                # Look ahead for balance and value
                state_text = ""
                j = i
                while j < min(i+10, len(lines)) and j < len(lines):
                    state_text += lines[j]
                    j += 1
                
                state_match = self.autobalancer_state_pattern.search(state_text)
                if state_match:
                    balance = self.parse_decimal(state_match.group(1))
                    total_value = self.parse_decimal(state_match.group(2))
                    
                    # Verify if we have YieldToken price
                    if "YieldToken" in self.current_prices:
                        expected_value = balance * self.current_prices["YieldToken"]
                        calc = Calculation(
                            line_number=i+1,
                            description="AutoBalancer value verification",
                            formula=f"{balance} * {self.current_prices['YieldToken']}",
                            operand1=balance,
                            operand2=self.current_prices["YieldToken"],
                            expected_result=total_value
                        )
                        self.verify_calculation(calc)
                        self.calculations.append(calc)
            
            i += 1
    
    def verify_calculation(self, calc: Calculation):
        """Verify a single calculation using relative and absolute tolerance"""
        actual = calc.operand1 * calc.operand2
        calc.actual_result = actual
        
        # Use is_close for comparison
        if not is_close(actual, calc.expected_result):
            # Calculate both absolute and relative error for reporting
            abs_error = abs(actual - calc.expected_result)
            rel_error = abs_error / max(abs(actual), abs(calc.expected_result)) if max(abs(actual), abs(calc.expected_result)) > 0 else Decimal('0')
            
            error_msg = f"Line {calc.line_number}: {calc.description} - Expected {calc.expected_result}, got {actual} (abs diff: {abs_error}, rel diff: {rel_error * 100:.6f}%)"
            calc.error = error_msg
            self.errors.append(error_msg)
    
    def verify_health_ratios(self):
        """Verify health ratio calculations and bounds"""
        for health in self.health_checks:
            # Health should be positive
            if health.health < 0:
                self.errors.append(f"Line {health.line_number}: Negative health ratio {health.health}")
            
            # Extreme health values might indicate calculation errors
            if health.health > 1000000:
                self.errors.append(f"Line {health.line_number}: Extremely high health ratio {health.health} - possible calculation error")
    
    def verify_rebalancing_logic(self):
        """Verify rebalancing follows protocol rules - improved version"""
        MIN_HEALTH = Decimal('1.1')
        TARGET_HEALTH = Decimal('1.3')
        MAX_HEALTH = Decimal('1.5')
        
        # Look for rebalancing sequences within a window
        for i in range(len(self.health_checks)):
            current = self.health_checks[i]
            
            # Look for "before rebalance" in the line
            if "before" in current.full_line.lower() and "rebalance" in current.full_line.lower():
                # Find corresponding "after" within next 10 health checks
                for j in range(i+1, min(i+10, len(self.health_checks))):
                    next_check = self.health_checks[j]
                    if "after" in next_check.full_line.lower() and "rebalance" in next_check.full_line.lower():
                        before = current.health
                        after = next_check.health
                        
                        # Check rebalancing effectiveness
                        if before < MIN_HEALTH and after < MIN_HEALTH:
                            self.errors.append(f"Line {current.line_number}: Health still below minHealth ({MIN_HEALTH}) after rebalance: {before} → {after}")
                        
                        if before > MAX_HEALTH and after > TARGET_HEALTH:
                            self.errors.append(f"Line {current.line_number}: Health not reduced to target ({TARGET_HEALTH}) when above maxHealth ({MAX_HEALTH}): {before} → {after}")
                        
                        # Check if rebalancing moved in the right direction
                        if before < MIN_HEALTH and after < before:
                            self.errors.append(f"Line {current.line_number}: Health moved in wrong direction (decreased) when below minimum: {before} → {after}")
                        
                        if before > MAX_HEALTH and after > before:
                            self.errors.append(f"Line {current.line_number}: Health moved in wrong direction (increased) when above maximum: {before} → {after}")
                        
                        break
    
    def generate_report(self):
        """Generate a comprehensive verification report"""
        print("=" * 80)
        print("TIDAL PROTOCOL TEST CALCULATION VERIFICATION REPORT")
        print("=" * 80)
        print(f"\nLog file: {self.log_file}")
        print(f"Total calculations verified: {len(self.calculations)}")
        print(f"Total price updates: {len(self.price_updates)}")
        print(f"Total health checks: {len(self.health_checks)}")
        print(f"Total errors found: {len(self.errors)}")
        
        if self.errors:
            print("\n" + "="*80)
            print("ERRORS FOUND:")
            print("="*80)
            for error in self.errors:
                print(f"❌ {error}")
        else:
            print("\n✅ All calculations verified successfully!")
        
        # Summary of calculations
        print("\n" + "="*80)
        print("CALCULATION SUMMARY:")
        print("="*80)
        
        correct_calcs = [c for c in self.calculations if c.error is None]
        incorrect_calcs = [c for c in self.calculations if c.error is not None]
        
        print(f"Correct calculations: {len(correct_calcs)}")
        print(f"Incorrect calculations: {len(incorrect_calcs)}")
        
        if incorrect_calcs:
            print("\nIncorrect calculations detail:")
            for calc in incorrect_calcs[:10]:  # Show first 10
                print(f"  Line {calc.line_number}: {calc.formula} = {calc.expected_result} (actual: {calc.actual_result})")
            if len(incorrect_calcs) > 10:
                print(f"  ... and {len(incorrect_calcs) - 10} more")
        
        # Price history
        print("\n" + "="*80)
        print("PRICE HISTORY:")
        print("="*80)
        current_prices = {}
        for update in self.price_updates:
            if update.token not in current_prices or current_prices[update.token] != update.price:
                print(f"Line {update.line_number}: {update.token} = {update.price}")
                current_prices[update.token] = update.price
        
        # Health ratio analysis
        print("\n" + "="*80)
        print("HEALTH RATIO ANALYSIS:")
        print("="*80)
        
        if self.health_checks:
            healths = [h.health for h in self.health_checks]
            min_health = min(healths)
            max_health = max(healths)
            
            print(f"Min health observed: {min_health}")
            print(f"Max health observed: {max_health}")
            
            # Find critical health situations
            critical_healths = [h for h in self.health_checks if h.health < Decimal('0.1')]
            if critical_healths:
                print(f"\n⚠️  Critical health situations (<0.1): {len(critical_healths)}")
                for h in critical_healths[:5]:  # Show first 5
                    print(f"  Line {h.line_number}: {h.health}")
                    
            # Health distribution
            print("\nHealth distribution:")
            print(f"  Critical (<0.1): {len([h for h in healths if h < Decimal('0.1')])}")
            print(f"  Below min (0.1-1.1): {len([h for h in healths if Decimal('0.1') <= h < Decimal('1.1')])}")
            print(f"  In range (1.1-1.5): {len([h for h in healths if Decimal('1.1') <= h <= Decimal('1.5')])}")
            print(f"  Above max (>1.5): {len([h for h in healths if h > Decimal('1.5')])}")
        
        return len(self.errors) == 0

def main():
    if len(sys.argv) < 2:
        log_file = "full_test_output.log"
    else:
        log_file = sys.argv[1]
    
    verifier = TestLogVerifier(log_file)
    
    print("Parsing log file...")
    verifier.parse_log()
    
    print("Verifying health ratios...")
    verifier.verify_health_ratios()
    
    print("Verifying rebalancing logic...")
    verifier.verify_rebalancing_logic()
    
    print("\nGenerating report...\n")
    success = verifier.generate_report()
    
    # Save detailed results to JSON
    results = {
        "success": success,
        "total_calculations": len(verifier.calculations),
        "total_errors": len(verifier.errors),
        "errors": verifier.errors,
        "calculations": [
            {
                "line": c.line_number,
                "formula": c.formula,
                "expected": str(c.expected_result),
                "actual": str(c.actual_result) if c.actual_result else None,
                "error": c.error
            }
            for c in verifier.calculations
        ],
        "price_updates": [
            {
                "line": p.line_number,
                "token": p.token,
                "price": str(p.price)
            }
            for p in verifier.price_updates
        ]
    }
    
    with open("verification_results.json", "w") as f:
        json.dump(results, f, indent=2)
    
    print(f"\nDetailed results saved to verification_results.json")
    
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main() 