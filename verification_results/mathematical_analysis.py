#!/usr/bin/env python3
"""
Mathematical Analysis of Tidal Protocol Test Results
Properly handles ANSI color codes and extracts correct prices
Production-grade version with proper financial precision
"""

import re
import sys
from decimal import Decimal, getcontext, ROUND_HALF_EVEN
from collections import defaultdict
import json

# Set high precision for financial calculations
getcontext().prec = 28
getcontext().rounding = ROUND_HALF_EVEN

def strip_ansi_codes(text):
    """Remove ANSI color codes from text"""
    ansi_escape = re.compile(r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])')
    return ansi_escape.sub('', text)

def is_close(a: Decimal, b: Decimal, rel_tol=Decimal('1e-8'), abs_tol=Decimal('1e-12')) -> bool:
    """Compare two decimals with both relative and absolute tolerance"""
    return abs(a - b) <= max(abs_tol, rel_tol * max(abs(a), abs(b)))

def parse_decimal(value_str: str) -> Decimal:
    """Parse a decimal value, handling commas and scientific notation"""
    value_str = value_str.replace(',', '')
    if 'e' in value_str.lower():
        return Decimal(value_str)
    return Decimal(value_str)

class MathematicalAnalyzer:
    def __init__(self, log_file: str):
        self.log_file = log_file
        self.health_formulas = []
        self.rebalance_effects = []
        self.price_impacts = []
        self.critical_findings = []
        self.price_history = []  # Track all price changes
        self.balance_history = []  # Track all balance changes
        
        # Patterns for comprehensive logging format (handles both Unicode and escaped formats)
        self.comprehensive_price_pattern = re.compile(r'\|\s*(FLOW|YieldToken|MOET):\s*([0-9.,]+)')
        self.comprehensive_balance_pattern = re.compile(r'\|\s*(FLOW Collateral|MOET Debt|YieldToken Balance):\s*([0-9.,]+)')
        self.comprehensive_value_pattern = re.compile(r'\|\s*->\s*Value(?:\s+in MOET)?:\s*([0-9.,]+)')
        
    def analyze(self):
        """Extract and analyze mathematical relationships"""
        with open(self.log_file, 'r') as f:
            content = f.read()
            
        # Strip ANSI codes from entire content
        content = strip_ansi_codes(content)
            
        # Split by test scenarios
        # Look for test scenarios marked with |== 
        scenario_pattern = re.compile(r'\|== (AUTO-BORROW SCENARIO|AUTO-BALANCER SCENARIO):\s*([^=]+)')
        
        # Also treat the entire content as one scenario for simpler logs
        self._analyze_scenario(content)
            
    def _analyze_scenario(self, scenario: str):
        """Analyze a single test scenario"""
        lines = scenario.split('\n')
        scenario_name = lines[0].strip() if lines else "Unknown"
        
        # Track state
        current_flow_price = Decimal('1.0')
        current_yield_price = Decimal('1.0')
        current_moet_price = Decimal('1.0')
        
        for i, line in enumerate(lines):
            # Price updates
            if "[PRICE UPDATE]" in line and i+3 < len(lines):
                token, price = self._extract_price_update(lines[i:i+4])
                if token and price:
                    if token == "FLOW":
                        current_flow_price = price
                        self.price_history.append({
                            "line": i,
                            "token": "FLOW",
                            "price": price,
                            "scenario": scenario_name
                        })
                    elif token == "YieldToken":
                        current_yield_price = price
                        self.price_history.append({
                            "line": i,
                            "token": "YieldToken",
                            "price": price,
                            "scenario": scenario_name
                        })
                    elif token == "MOET":
                        current_moet_price = price
                        self.price_history.append({
                            "line": i,
                            "token": "MOET",
                            "price": price,
                            "scenario": scenario_name
                        })
                    
            # Health calculations
            if "Health before rebalance:" in line:
                health_before = self._extract_number(line)
                # Look for after
                for j in range(i+1, min(i+10, len(lines))):
                    if "Health after rebalance:" in lines[j]:
                        health_after = self._extract_number(lines[j])
                        self._analyze_health_change(
                            health_before, health_after, 
                            current_flow_price, scenario_name
                        )
                        break
                        
            # Balance calculations  
            if "AUTO-BALANCER STATE:" in line:
                # Extract balance, value, and price from the state itself
                balance = None
                calculated_value = None
                state_price = None
                
                for j in range(i, min(i+10, len(lines))):
                    if "YieldToken Balance:" in lines[j]:
                        match = re.search(r'YieldToken Balance:\s*([0-9][0-9.,]*)', lines[j])
                        if match:
                            balance = parse_decimal(match.group(1))
                    if "YieldToken Price:" in lines[j]:
                        match = re.search(r'YieldToken Price:\s*([0-9][0-9.,]*)', lines[j])
                        if match:
                            state_price = parse_decimal(match.group(1))
                    if "Total Value in MOET:" in lines[j]:
                        match = re.search(r'Total Value in MOET:\s*([0-9][0-9.,]*)', lines[j])
                        if match:
                            calculated_value = parse_decimal(match.group(1))
                            
                # Use the price from the state if available
                price_to_use = state_price if state_price else current_yield_price
                
                if balance is not None and calculated_value is not None:
                    expected = balance * price_to_use
                    self._verify_value_calculation(
                        balance, price_to_use, calculated_value, expected, scenario_name
                    )
                    
            # Comprehensive logging format parsing
            if "POSITION STATE:" in line or "AUTO-BALANCER STATE:" in line:
                # Look ahead for the full state block
                state_lines = []
                j = i
                while j < min(i+30, len(lines)) and "╚" not in lines[j]:
                    state_lines.append(lines[j])
                    j += 1
                state_text = '\n'.join(state_lines)
                
                # Extract all prices from comprehensive format
                price_matches = self.comprehensive_price_pattern.findall(state_text)
                for token, price in price_matches:
                    price_val = parse_decimal(price)
                    self.price_history.append({
                        "line": i,
                        "token": token,
                        "price": price_val,
                        "scenario": scenario_name,
                        "format": "comprehensive"
                    })
                
                # Extract all balances from comprehensive format
                balance_matches = self.comprehensive_balance_pattern.findall(state_text)
                for balance_type, amount in balance_matches:
                    amount_val = parse_decimal(amount)
                    token_name = "FLOW" if "FLOW" in balance_type else ("MOET" if "MOET" in balance_type else "YieldToken")
                    self.balance_history.append({
                        "line": i,
                        "token": token_name,
                        "balance": amount_val,
                        "type": balance_type,
                        "scenario": scenario_name
                    })
                    
    def _extract_price_update(self, lines):
        """Extract token and price from price update lines"""
        token = None
        price = None
        
        for line in lines:
            if "Token Identifier:" in line:
                if "FlowToken" in line:
                    token = "FLOW"
                elif "YieldToken" in line:
                    token = "YieldToken"
                elif "MOET" in line:
                    token = "MOET"
            if "New Price:" in line:
                # Extract price more carefully, avoiding timestamps
                match = re.search(r'New Price:\s*([0-9]+\.?[0-9]*)\s*MOET', line)
                if match:
                    price = parse_decimal(match.group(1))
                    
        return token, price
        
    def _extract_number(self, line):
        """Extract decimal number from line"""
        # Skip lines that are mostly separators
        if line.count('=') > 10 or line.count('-') > 10:
            return None
            
        # For health lines, look specifically after "rebalance:"
        if "Health" in line and "rebalance:" in line:
            match = re.search(r'rebalance:\s*([0-9]+\.?[0-9]*)', line)
            if match:
                return parse_decimal(match.group(1))
                
        # For other lines, look for numbers after the last colon
        # Find the last colon and extract number after it
        last_colon = line.rfind(':')
        if last_colon != -1:
            remainder = line[last_colon+1:].strip()
            match = re.search(r'^([0-9]+\.?[0-9]*)', remainder)
            if match:
                return parse_decimal(match.group(1))
                
        # Fallback: try to find a decimal number
        match = re.search(r'\b([0-9]+\.[0-9]+)\b', line)
        if match:
            return parse_decimal(match.group(1))
            
        return None
        
    def _analyze_health_change(self, before, after, flow_price, scenario):
        """Analyze health ratio changes"""
        MIN_HEALTH = Decimal('1.1')
        TARGET_HEALTH = Decimal('1.3')
        MAX_HEALTH = Decimal('1.5')
        
        if before is not None and after is not None:
            change = after - before
            
            # Guard against division by zero
            if before == 0:
                if after != 0:
                    self.critical_findings.append({
                        "type": "Health from zero",
                        "scenario": scenario,
                        "before": str(before),
                        "after": str(after),
                        "issue": "Health changed from zero to non-zero"
                    })
            else:
                change_pct = (change / before * 100)
                
                # Check for extreme changes
                if abs(change_pct) > 1000:
                    self.critical_findings.append({
                        "type": "Extreme health change",
                        "scenario": scenario,
                        "before": str(before),
                        "after": str(after),
                        "change_pct": str(change_pct),
                        "flow_price": str(flow_price)
                    })
                
            # Check rebalancing effectiveness
            if before < MIN_HEALTH and after < MIN_HEALTH:
                self.critical_findings.append({
                    "type": "Ineffective rebalance",
                    "scenario": scenario,
                    "before": str(before),
                    "after": str(after),
                    "issue": "Health still below MIN_HEALTH after rebalance"
                })
                
            # Check if moved in right direction
            direction_improved = False
            if before < MIN_HEALTH:
                direction_improved = after > before  # Should increase
            elif before > MAX_HEALTH:
                direction_improved = after < before  # Should decrease
            else:
                direction_improved = True  # Already in range
                
            self.rebalance_effects.append({
                "scenario": scenario,
                "before": before,
                "after": after,
                "change": change,
                "flow_price": flow_price,
                "direction_improved": direction_improved,
                "distance_from_target": abs(after - TARGET_HEALTH)
            })
            
    def _verify_value_calculation(self, balance, price, stated_value, expected_value, scenario):
        """Verify value calculations with proper error handling"""
        # Guard against zero expected value
        if expected_value == 0:
            if stated_value != 0:
                self.critical_findings.append({
                    "type": "Value mismatch with zero",
                    "scenario": scenario,
                    "balance": str(balance),
                    "price": str(price),
                    "stated": str(stated_value),
                    "expected": str(expected_value),
                    "issue": "Non-zero value with zero expected"
                })
        else:
            # Use is_close for comparison
            if not is_close(stated_value, expected_value, rel_tol=Decimal('0.0001')):  # 0.01% tolerance
                error = abs(stated_value - expected_value)
                error_pct = (error / expected_value * 100)
                
                self.critical_findings.append({
                    "type": "Calculation error",
                    "scenario": scenario,
                    "balance": str(balance),
                    "price": str(price),
                    "stated": str(stated_value),
                    "expected": str(expected_value),
                    "error_pct": str(error_pct)
                })
                
    def generate_report(self):
        """Generate comprehensive mathematical analysis report"""
        print("=" * 80)
        print("MATHEMATICAL ANALYSIS REPORT")
        print("=" * 80)
        
        # Show price history summary
        print(f"\n📊 PRICE HISTORY SUMMARY")
        print("=" * 80)
        if self.price_history:
            # Group by token
            by_token = defaultdict(set)
            for p in self.price_history:
                by_token[p["token"]].add(str(p["price"]))
            
            for token, prices in by_token.items():
                sorted_prices = sorted([Decimal(p) for p in prices])
                print(f"\n{token} prices used in tests:")
                print(f"  Range: {min(sorted_prices)} to {max(sorted_prices)}")
                print(f"  Unique values: {', '.join(str(p) for p in sorted_prices[:10])}")
                if len(sorted_prices) > 10:
                    print(f"  ... and {len(sorted_prices)-10} more")
        
        # Critical findings
        if self.critical_findings:
            print(f"\n🚨 CRITICAL FINDINGS: {len(self.critical_findings)}")
            print("=" * 80)
            
            # Group by type
            by_type = defaultdict(list)
            for finding in self.critical_findings:
                by_type[finding["type"]].append(finding)
                
            for finding_type, findings in by_type.items():
                print(f"\n{finding_type} ({len(findings)} instances):")
                for f in findings[:3]:  # Show first 3
                    print(f"  - {json.dumps(f, indent=4)}")
                if len(findings) > 3:
                    print(f"  ... and {len(findings)-3} more")
                    
        # Rebalancing effectiveness
        print("\n" + "="*80)
        print("REBALANCING EFFECTIVENESS ANALYSIS")
        print("="*80)
        
        if self.rebalance_effects:
            total = len(self.rebalance_effects)
            direction_improved = sum(1 for r in self.rebalance_effects if r['direction_improved'])
            optimal = sum(1 for r in self.rebalance_effects 
                         if Decimal('1.1') <= r['after'] <= Decimal('1.5'))
            
            print(f"Total rebalances: {total}")
            print(f"Moved in correct direction: {direction_improved} ({direction_improved/total*100:.1f}%)")
            print(f"Reached optimal range (1.1-1.5): {optimal} ({optimal/total*100:.1f}%)")
            
            # Find worst cases - sorted by distance from target
            TARGET_HEALTH = Decimal('1.3')
            worst = sorted(self.rebalance_effects, 
                          key=lambda x: x['distance_from_target'], 
                          reverse=True)[:5]
            
            print("\nWorst post-rebalance healths (furthest from target 1.3):")
            for r in worst:
                print(f"  {r['scenario']}: {r['after']:.6f} (from {r['before']:.6f}, distance: {r['distance_from_target']:.6f})")
                print(f"    FLOW price at time: {r['flow_price']}")
                
        # Balance history summary for all 3 tokens
        if self.balance_history:
            print("\n" + "="*80)
            print("BALANCE HISTORY SUMMARY (All 3 Tokens):")
            print("="*80)
            
            # Group by token
            by_token = defaultdict(list)
            for b in self.balance_history:
                by_token[b["token"]].append(b)
            
            for token in ["FLOW", "MOET", "YieldToken"]:
                if token in by_token:
                    balances = [Decimal(b["balance"]) for b in by_token[token]]
                    print(f"\n{token}:")
                    print(f"  Total observations: {len(balances)}")
                    print(f"  Range: {min(balances)} to {max(balances)}")
                    zero_count = sum(1 for b in balances if b == 0)
                    if zero_count > 0:
                        print(f"  Zero balances: {zero_count}")
        
        # Save detailed results
        results = {
            "critical_findings": self.critical_findings,
            "rebalance_effects": [
                {
                    "scenario": r["scenario"],
                    "before": str(r["before"]),
                    "after": str(r["after"]),
                    "change": str(r["change"]),
                    "flow_price": str(r["flow_price"]),
                    "direction_improved": r["direction_improved"],
                    "distance_from_target": str(r["distance_from_target"])
                }
                for r in self.rebalance_effects
            ],
            "price_history": [
                {
                    "token": p["token"],
                    "price": str(p["price"]),
                    "scenario": p["scenario"]
                }
                for p in self.price_history
            ],
            "balance_history": [
                {
                    "token": b["token"],
                    "balance": str(b["balance"]),
                    "type": b["type"],
                    "scenario": b["scenario"]
                }
                for b in self.balance_history
            ],
            "summary": {
                "total_critical_findings": len(self.critical_findings),
                "total_rebalances": len(self.rebalance_effects),
                "rebalances_correct_direction": sum(1 for r in self.rebalance_effects if r['direction_improved']),
                "rebalances_optimal_range": sum(1 for r in self.rebalance_effects if Decimal('1.1') <= r['after'] <= Decimal('1.5')),
                "tokens_tracked": {
                    "FLOW": len([b for b in self.balance_history if b["token"] == "FLOW"]),
                    "MOET": len([b for b in self.balance_history if b["token"] == "MOET"]),
                    "YieldToken": len([b for b in self.balance_history if b["token"] == "YieldToken"])
                }
            }
        }
        
        with open("mathematical_analysis.json", "w") as f:
            json.dump(results, f, indent=2)
            
        print("\nDetailed results saved to mathematical_analysis.json")
        
        return len(self.critical_findings) == 0

def main():
    log_file = sys.argv[1] if len(sys.argv) > 1 else "full_test_output.log"
    
    analyzer = MathematicalAnalyzer(log_file)
    print(f"Analyzing mathematical relationships in {log_file}...")
    analyzer.analyze()
    
    success = analyzer.generate_report()
    sys.exit(0 if success else 1)

if __name__ == "__main__":
    main() 