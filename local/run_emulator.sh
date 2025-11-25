flow emulator --contracts --transaction-expiry 1000 &

# Port to check
PORT=8080

# Wait for port to be available
echo "Waiting for port $PORT to be ready..."
while ! nc -z localhost $PORT; do
  sleep 1
done
