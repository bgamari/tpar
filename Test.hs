import Test.QuickCheck
import qualified TPar.SubPubStream.Test

main :: IO ()
main = quickCheck TPar.SubPubStream.Test.test
