def get_iam_token(api_key, only_token=True):
    """Get IBM Cloud IAM token using an HTTP request.

    Args:
        api_key: IBM Cloud API key
        only_token: If True, return only the access token string.
                    If False, return the full response object.

    Returns:
        str or Response: Access token string if only_token=True,
                        otherwise the full response object.
    """
    import requests
    import certifi

    token_response = requests.post(
        "https://iam.cloud.ibm.com/identity/token",
        headers={"Content-Type": "application/x-www-form-urlencoded"},
        data={
            "grant_type": "urn:ibm:params:oauth:grant-type:apikey",
            "apikey": api_key,
        },
        verify=certifi.where(),
    )
    print(token_response)

    if only_token:
        return token_response.json().get("access_token")
    else:
        return token_response


def auth_iam_token(api_key, only_token=True):
    """Get IBM Cloud IAM token using the IBM Cloud SDK.

    Args:
        api_key: IBM Cloud API key
        only_token: If True, return only the access token string.
                    If False, return the full token response dict.

    Returns:
        str or dict: Access token string if only_token=True,
                    otherwise the full token response dictionary.
    """
    from ibm_cloud_sdk_core.authenticators import IAMAuthenticator

    authenticator = IAMAuthenticator(api_key)
    token_response = authenticator.token_manager.request_token()

    if only_token:
        return token_response.get("access_token")
    else:
        return token_response


def generate_zen_auth_header(username, api_key):
    """Generate a Zen API authorization header.

    Args:
        username: Zen username
        api_key: Zen API key

    Returns:
        str: Authorization header value in format "ZenApiKey <encoded_credentials>"
    """
    import base64

    credentials = f"{username}:{api_key}"
    encoded = base64.b64encode(credentials.encode()).decode()

    return f"ZenApiKey {encoded}"
