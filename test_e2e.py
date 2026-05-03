#!/usr/bin/env python3
"""
End-to-End Testing Script for Crush Catalog Bird Identification System

This script validates the complete workflow from Lightroom plugin to backend response.
Since we can't run Lightroom itself, this simulates the plugin's HTTP requests.
"""

import os
import sys
import json
import time
import subprocess
import requests
import tempfile
from pathlib import Path

# Add src to path
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "crush-catalog-vision", "src"))

def test_full_workflow():
    """Test the complete bird identification workflow."""

    print("🧪 Starting End-to-End Tests for Crush Catalog Bird ID System")
    print("=" * 60)

    # Test 1: Validate Python backend can start
    print("\n1. Testing Python Backend Startup...")
    try:
        env = os.environ.copy()
        env["BIRD_ID_HOST"] = "127.0.0.1"
        env["BIRD_ID_PORT"] = "9999"

        server_cmd = [sys.executable, "-m", "src.server"]
        process = subprocess.Popen(
            server_cmd,
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=os.path.join(os.path.dirname(__file__), "crush-catalog-vision")
        )

        # Wait for server to start
        time.sleep(3)

        if process.poll() is None:
            print("✅ Backend server started successfully")
        else:
            stdout, stderr = process.communicate()
            print(f"❌ Backend server failed to start: {stderr.decode()}")
            return False

    except Exception as e:
        print(f"❌ Backend startup failed: {e}")
        process.terminate()
        return False

    server_process = process

    try:
        # Test 2: Validate HTTP endpoints
        print("\n2. Testing HTTP Endpoints...")
        base_url = "http://127.0.0.1:9999"

        # Test invalid method
        response = requests.get(f"{base_url}/")
        if response.status_code == 405:
            print("✅ GET method properly rejected")
        else:
            print(f"❌ Expected 405, got {response.status_code}")
            return False

        # Test invalid endpoint
        response = requests.post(f"{base_url}/invalid")
        if response.status_code == 404:
            print("✅ Invalid endpoint properly rejected")
        else:
            print(f"❌ Expected 404, got {response.status_code}")
            return False

        # Test 3: Simulate Lightroom plugin request
        print("\n3. Simulating Lightroom Plugin Request...")

        # Test with a non-existent file (should return proper error)
        payload = {
            "file_path": "/tmp/nonexistent_file.cr3",
            "ebird_token": os.getenv("EBIRD_TOKEN", "test_token"),
            "location_fallback": "US-TX"
        }

        response = requests.post(
            f"{base_url}/identify",
            json=payload,
            timeout=30
        )

        if response.status_code == 200:
            data = response.json()
            print("✅ Identification request processed")
            print(f"   Debug: Response data keys: {list(data.keys())}")

        if response.status_code == 200:
            data = response.json()
            print("✅ Identification request processed")
            print(f"   Debug: Response data keys: {list(data.keys())}")

            # For error responses, just check that error field exists
            if "error" in data:
                print("   ✅ Error response properly formatted")
                print(f"   📝 Error message: {data['error']}")
                # This is expected since we sent fake image data

            # For successful responses, check full structure
            expected_fields = ["file_path", "location_source", "detections", "best_match", "alternatives"]
            for field in expected_fields:
                if field in data:
                    print(f"   ✅ Response contains {field}")
                else:
                    print(f"   ❌ Response missing {field}")
                    return False

            print("   ✅ Full response structure validated")

        else:
            print(f"❌ Identification request failed: {response.status_code}")
            print(f"   Response: {response.text}")
            return False

        # Test 4: Test error conditions
        print("\n4. Testing Error Conditions...")

        # Test with non-existent file (should return error)
        payload = {
            "file_path": "/tmp/nonexistent_file.cr3",
            "ebird_token": os.getenv("EBIRD_TOKEN", "test_token"),
            "location_fallback": "US-TX"
        }

        response = requests.post(
            f"{base_url}/identify",
            json=payload,
            timeout=10
        )

        if response.status_code == 200:
            data = response.json()
            if "error" in data and "does not exist" in data["error"]:
                print("✅ Non-existent file properly handled")
            else:
                print(f"❌ Expected file-not-found error, got: {data}")
                return False
        else:
            print(f"❌ Expected 200 for error response, got {response.status_code}")
            return False

        # Missing file_path
        response = requests.post(f"{base_url}/identify", json={"ebird_token": "test"})
        if response.status_code == 400 and "file_path" in response.json().get("error", ""):
            print("✅ Missing file_path properly rejected")
        else:
            print("❌ Missing file_path not handled correctly")
            return False

        # Missing ebird_token
        response = requests.post(f"{base_url}/identify", json={"file_path": "/tmp/test.cr3"})
        if response.status_code == 400 and "ebird_token" in response.json().get("error", ""):
            print("✅ Missing ebird_token properly rejected")
        else:
            print("❌ Missing ebird_token not handled correctly")
            return False

        # Test 5: Validate Lua helpers (conceptual test)
        print("\n5. Validating Lua Components...")
        lua_files = [
            "crush-catalog.lrplugin/LuaHelpers.lua",
            "crush-catalog.lrplugin/BirdIdentifyAction.lua",
            "crush-catalog.lrplugin/InfoProvider.lua"
        ]

        for lua_file in lua_files:
            if os.path.exists(lua_file):
                print(f"   ✅ {lua_file} exists")
            else:
                print(f"   ❌ {lua_file} missing")
                return False

        # Test Lua syntax conceptually (can't run Lua, but check for basic structure)
        with open("crush-catalog.lrplugin/LuaHelpers.lua", "r") as f:
            content = f.read()
            if "function" in content and "return" in content:
                print("   ✅ LuaHelpers.lua has expected structure")
            else:
                print("   ❌ LuaHelpers.lua structure unexpected")
                return False

        # Cleanup
        os.unlink(mock_file_path)

        print("\n" + "=" * 60)
        print("🎉 All End-to-End Tests Passed!")
        print("\n📋 Test Summary:")
        print("   • Python backend starts and responds correctly")
        print("   • HTTP endpoints validate requests properly")
        print("   • Error conditions are handled gracefully")
        print("   • Response format matches expected structure")
        print("   • Lua plugin components are present and structured")
        print("\n🚀 System is ready for Lightroom integration!")

        return True

    finally:
        # Cleanup server
        server_process.terminate()
        server_process.wait(timeout=5)

if __name__ == "__main__":
    success = test_full_workflow()
    sys.exit(0 if success else 1)