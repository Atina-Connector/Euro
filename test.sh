# ============================================================
# 1. LOGIN
#  ============================================================
#
echo "Realizando login..."
LOGIN_RESPONSE=$(curl --silent --location 'http://localhost:8086/v1/session/login' \
	--header 'Accept: application/json' \
	--header 'Content-Type: application/json' \
	--header 'correlationUUID: ACME-d2cfc11c-0b99-4434-a97c-f2294e0b9018' \
	--data  '{   "user": "ATINAD",
		     "environment": "JUAT920",
		     "password": "9-Fsn_&C$W<94d7KWKjisul",
		     "wsconnection": false,
		     "role": "*ALL",
		     "transactionID": 0
	    	 }')

echo "Respuesta del login:"
echo "$LOGIN_RESPONSE"
echo

JWT_TOKEN=$(echo "$LOGIN_RESPONSE" | python3 -c \
  'import sys,json; print(json.load(sys.stdin).get("jwtToken",""))')

SESSION_ID=$(echo "$LOGIN_RESPONSE" | python3 -c \
  'import sys,json; print(json.load(sys.stdin).get("sessionId",""))')

# Validar que obtuvimos el token
if [ -z "$JWT_TOKEN" ]; then
echo "ERROR: No se pudo obtener jwtToken del login."
exit 1
fi

echo "Ejecutando AddressBookMasterMBF..."

curl --location 'http://localhost:8086/v1/operations/execute' \
--header "Token: $JWT_TOKEN" \
--header 'Accept: application/json' \
--header 'Content-Type: application/json' \
--header 'Accept-Encoding: gzip, deflate, br' \
--header 'TransactionId: 0' \
--header 'correlationUUID: ACME-d2cfc11c-0b99-4434-a97c-f2294e0b9018' \
--header "Authorization: Bearer $JWT_TOKEN" \
--data '{
  "operacionKey": "AddressBookMasterMBF",
  "listaDeValores": {
    "cActionCode": "I",
    "szVersion": "ZJDE0001",
    "mnAddressBookNumber": 1
  },
  "connectorName": "BSFN",
  "transactionID": 502960
}'

echo "submit UBE"
curl --location 'http://localhost:8086/v1/operations/execute' --header "Token: $JWT_TOKEN" --header 'Content-Type: application/json' --header 'Accept-Encoding: gzip, deflate, br' --header 'TransactionId: 0' --header 'correlationUUID: ACME-1eed3908-9ea6-4925-958d-fdb10717c689' --header "Authorization: Bearer $JWT_TOKEN" --data '{ "operacionKey": "R01010Z-ZJDE0001", "listaDeValores": { "Report Interconnect": { "szEdiUserIdData": "JDE", "szEdiTransactNumberData": "100"}, "Processing Options": { "Versionconsolidated": "ZJDE0001"}, "Job Queue": "QBATCH", "Data Selection": "F0101.EDUS='\''JDE'\''"}, "connectorName": "UBE", "transactionID": 502960}'
