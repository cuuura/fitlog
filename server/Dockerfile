# Render(무료 테스트 서버) 전용: 서버를 여기서 컴파일하지 않고, GitHub Actions(server-image.yml)가
# server/Dockerfile.build 로 빌드해 올린 이미지를 그대로 쓴다.
# Render 무료 빌드 머신은 메모리가 작아 Kotlin 컴파일이 도중에 죽으며 "Exited with status 1" 로 배포가 실패했다.
#
# 순서 주의: main 푸시 직후 Render 가 바로 빌드하면 아직 이전 latest 를 받는다.
# server-image 워크플로가 이미지를 올린 뒤 Render 배포 훅(secrets.RENDER_DEPLOY_HOOK_URL)을 불러 최신 이미지로 다시 배포한다.
# 직접 빌드(로컬·Portainer 등)는 server/Dockerfile.build 를 쓴다.
FROM ghcr.io/cuuura/fitlog-server:latest
