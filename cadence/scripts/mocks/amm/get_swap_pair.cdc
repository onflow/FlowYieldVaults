import "SwapPair"
import "SwapFactory"

access(all) fun main(): AnyStruct? {

    return SwapFactory.getPairInfo(token0Key: "A.f8d6e0586b0a20c7.MOET", token1Key:"A.f8d6e0586b0a20c7.YieldToken" )
}
